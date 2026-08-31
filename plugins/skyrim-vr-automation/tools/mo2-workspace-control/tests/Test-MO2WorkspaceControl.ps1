# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param([switch]$DiscoveryOnly)

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-workspace-control-' + [guid]::NewGuid().ToString('N'))
$taskId = 'codex-test-task-001'
$priorProfileControlRoot = $env:CSX_MO2_PROFILE_CONTROL_ROOT
$priorShaderCacheControlRoot = $env:CSX_SHADER_CACHE_CONTROL_ROOT
$env:CSX_MO2_PROFILE_CONTROL_ROOT = Join-Path $fixture 'profile-transactions'
$env:CSX_SHADER_CACHE_CONTROL_ROOT = Join-Path $fixture 'shader-cache-transactions'
function Get-TestProfileFingerprint([string]$Path) {
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        if ($relative -match '^(?i:saves)[\\/]') { continue }
        $records += [pscustomobject][ordered]@{ path = $relative; bytes = [long]$file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    $canonical = $records | ConvertTo-Json -Compress -Depth 4
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
}
try {
    $mo2 = Join-Path $fixture 'MO2'; $profiles = Join-Path $mo2 'profiles'; $mods = Join-Path $mo2 'mods'
    $source = Join-Path $profiles 'Mad God Stable'; $loaderMod = Join-Path $mods 'Loader'; $sessions = Join-Path $fixture 'sessions'
    $synthesisMod = Join-Path $mods 'Synthesis Patch (SFW)'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $loaderMod 'SKSE\Plugins'), (Join-Path $synthesisMod 'ShaderCache\Lighting'), (Join-Path $synthesisMod 'backup\previous'), (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    @('+Loader', '+Synthesis Patch (SFW)') | Set-Content -LiteralPath (Join-Path $source 'modlist.txt') -Encoding utf8
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    "[custom_overwrites]`r`nsYnThEsIs=Synthesis Patch (SFW)`r`n" | Set-Content -LiteralPath (Join-Path $source 'settings.ini') -Encoding utf8 -NoNewline
    'ordinary-base-save' | Set-Content -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Encoding utf8
    'known-good-save' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.ess') -Encoding utf8
    'known-good-cosave' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.skse') -Encoding utf8
    'existing-provider' | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    'lower-provider-cache' | Set-Content -LiteralPath (Join-Path $synthesisMod 'ShaderCache\Lighting\later-area.pso') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $synthesisMod 'backup\hashes') -Encoding utf8 -NoNewline
    'older-generated-backup' | Set-Content -LiteralPath (Join-Path $synthesisMod 'backup\previous\shader.bin') -Encoding utf8
    foreach ($cachePath in @((Join-Path $mo2 'overwrite\ShaderCache'))) {
        New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
        ('compiled-' + [IO.Path]::GetFileName($cachePath)) | Set-Content -LiteralPath (Join-Path $cachePath 'fixture.bin') -Encoding utf8
    }
    New-Item -ItemType Directory -Path (Join-Path $mo2 'overwrite\backup') -Force | Out-Null
    'pre-task-overwrite-backup' | Set-Content -LiteralPath (Join-Path $mo2 'overwrite\backup\preexisting.bin') -Encoding utf8
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $ini = Join-Path $mo2 'ModOrganizer.ini'
    [IO.File]::WriteAllText(
        $ini,
        "[General]`r`nselected_profile=@ByteArray(Codex)`r`n[customExecutables]`r`n1\title=@ByteArray(Test)`r`n1\binary=@ByteArray($loader)`r`n1\workingDirectory=@ByteArray($fixture)`r`n",
        [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $fixture 'config.json'; $lock = Join-Path $sessions 'lock.json'
    $fixtureManifestPath = Join-Path $fixture 'known-good-saves.json'
    $saveFiles = @('Save2_KnownGood.ess', 'Save2_KnownGood.skse') | ForEach-Object {
        $path = Join-Path $source (Join-Path 'saves' $_)
        [ordered]@{ relativePath = $_; bytes = [long](Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    [ordered]@{ contractVersion='1.0.0'; sourceProfile='Mad God Stable'; profileFingerprintSha256=(Get-TestProfileFingerprint $source); defaultFixtureId='interior'; fixtures=@([ordered]@{id='interior';label='Known-good interior';location='TestCell';loadName='Save2_KnownGood';files=$saveFiles}) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding utf8
    [ordered]@{
        contractVersion='0.4.0'; machine='fixture'; mo2=[ordered]@{root=$mo2;executable=$mo2Exe;ini=$ini;profilesDirectory=$profiles;modsDirectory=$mods;overwriteDirectory=(Join-Path $mo2 'overwrite');logsDirectory=(Join-Path $mo2 'logs');rootBuilderDefinitions=@();rootBuilderDataDirectory=(Join-Path $mo2 'rb');processNames=@('WorkspaceImpossibleMO2');gameProcessNames=@('WorkspaceImpossibleGame');runtimeProcessNames=@()};
        defaults=[ordered]@{profile='Mad God Stable';testProfileSource='Mad God Stable';newGameFixtureManifest=$fixtureManifestPath;executable='Test'};storage=[ordered]@{sessionStaging=$sessions;archive=(Join-Path $fixture 'archive')};limits=[ordered]@{maxEnumeratedFiles=100;overwriteWarningFiles=10;overwriteBlockFiles=50;overwriteWarningBytes=1024;overwriteBlockBytes=4096;launchPendingGraceSeconds=30};session=[ordered]@{lockFile=$lock}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mo2-control\MO2Control.psm1') -Force
    $config = Read-MO2ControlConfig -ConfigPath $configPath
    $access = Invoke-MO2RequestAccess -Config $config -Label fixture; $accessId = [string]$access.data.access.accessId
    $escapedSource = Join-Path $mo2 'outside'
    New-Item -ItemType Directory -Path $escapedSource -Force | Out-Null
    '+Loader' | Set-Content -LiteralPath (Join-Path $escapedSource 'modlist.txt') -Encoding utf8
    $escapedStatus = & $entry fixture-status -ConfigPath $configPath -SourceProfile '..\outside' -Compact -NoExit | ConvertFrom-Json
    if ($escapedStatus.ok -or $escapedStatus.errors[0] -notmatch 'direct child|malformed') { throw 'SourceProfile traversal was not rejected as malformed.' }
    $fixtureStatusRaw = & $entry fixture-status -ConfigPath $configPath -Compact
    if ($fixtureStatusRaw -match "`r|`n") { throw 'Compact workspace output was not one line.' }
    $fixtureStatus = $fixtureStatusRaw | ConvertFrom-Json
    if (-not $fixtureStatus.ok -or $fixtureStatus.state -ne 'fixture-valid') { throw 'Fixture status did not validate the original manifest.' }
    $boundedStatus = & $entry fixture-status -ConfigPath $configPath -MaxProfileFiles 2 -Compact -NoExit | ConvertFrom-Json
    if ($boundedStatus.ok -or $boundedStatus.errors[0] -notmatch 'maximum file count') { throw 'Profile traversal did not enforce its declared file-count bound.' }
    $deadlineStatus = & $entry fixture-status -ConfigPath $configPath -InternalTestFailurePoint tree-operation-deadline -Compact -NoExit | ConvertFrom-Json
    if ($deadlineStatus.ok -or $deadlineStatus.errors[0] -notmatch 'shared .*tree-operation deadline') { throw 'Profile traversal did not enforce its shared total deadline.' }
    if (-not $fixtureStatus.data.approval.reusableApprovalEligible -or @($fixtureStatus.data.approval.reusablePrefix).Count -ne 6 -or $fixtureStatus.data.approval.reusablePrefix[4] -ne [IO.Path]::GetFullPath($entry) -or $fixtureStatus.data.approval.reusablePrefix[5] -ne 'fixture-status') { throw 'Fixture status did not expose its exact reusable approval prefix.' }
    $unconfiguredPath = Join-Path $fixture 'config-no-fixture.json'
    $unconfigured = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $unconfigured.defaults.PSObject.Properties.Remove('newGameFixtureManifest')
    $unconfigured | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unconfiguredPath -Encoding utf8
    $unconfiguredStatus = & $entry fixture-status -ConfigPath $unconfiguredPath -Compact | ConvertFrom-Json
    if (-not $unconfiguredStatus.ok -or $unconfiguredStatus.state -ne 'fixture-not-configured' -or @($unconfiguredStatus.data.guidance).Count -lt 3 -or -not (Test-Path -LiteralPath $unconfiguredStatus.data.exampleManifestPath -PathType Leaf)) { throw 'Fixture discovery did not explain an unconfigured manifest.' }
    $missingPath = Join-Path $fixture 'config-missing-fixture.json'
    $unconfigured.defaults | Add-Member -NotePropertyName newGameFixtureManifest -NotePropertyValue (Join-Path $fixture 'missing.json')
    $unconfigured | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingPath -Encoding utf8
    $missingStatus = & $entry fixture-status -ConfigPath $missingPath -Compact | ConvertFrom-Json
    if (-not $missingStatus.ok -or $missingStatus.state -ne 'fixture-manifest-missing' -or -not $missingStatus.data.configured -or $missingStatus.data.manifestExists) { throw 'Fixture discovery did not distinguish a configured missing manifest.' }
    if ($DiscoveryOnly) {
        $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
        if (-not $releasedAccess.ok) { throw 'Discovery-only access release failed.' }
        [pscustomobject]@{ ok = $true; assertions = 2; mode = 'discovery-only' } | ConvertTo-Json
        return
    }
    $prepared = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $prepared.ok -or $prepared.state -ne 'overwrite-preserved' -or -not (Test-Path -LiteralPath (Join-Path $mo2 'overwrite\ShaderCache\fixture.bin') -PathType Leaf)) { throw "Source preparation did not preserve MO2 Overwrite: $($prepared | ConvertTo-Json -Depth 8 -Compress)" }
    if (-not $prepared.data.approval.reusableApprovalEligible -or $prepared.data.approval.escalationUsuallyRequired -or $null -ne $prepared.data.approval.oneShotReason) { throw 'Non-mutating source preparation was incorrectly classified as elevated or one-shot.' }
    $unqualifiedCreate = & $entry create -ConfigPath $unconfiguredPath -AccessId $accessId -TaskId $taskId -Label unqualified -SavePolicy MainMenuOnly -Confirm:$false -NoExit | ConvertFrom-Json
    if ($unqualifiedCreate.ok -or $unqualifiedCreate.errors[0] -notmatch 'valid default world-entry save') { throw 'Fresh creation did not reject an unqualified maintained source profile.' }
    $missingFixtureCreate = & $entry create -ConfigPath $missingPath -AccessId $accessId -TaskId $taskId -Label missing-fixture -SavePolicy FreshGame -Confirm:$false -NoExit | ConvertFrom-Json
    if ($missingFixtureCreate.ok -or $missingFixtureCreate.errors[0] -notmatch 'valid default world-entry save') { throw 'Fresh creation did not reject a missing maintained world-entry fixture.' }
    'stable-profile-drift' | Set-Content -LiteralPath (Join-Path $source 'fixture-drift.txt') -Encoding utf8
    $staleStatus = & $entry fixture-status -ConfigPath $configPath -Compact | ConvertFrom-Json
    if ($staleStatus.state -ne 'fixture-stale' -or $staleStatus.data.expectedProfileFingerprintSha256 -eq $staleStatus.data.actualProfileFingerprintSha256) { throw 'Fixture drift did not report expected and actual fingerprints.' }
    $refreshedFixture = & $entry refresh-fixture -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $refreshedFixture.ok -or -not $refreshedFixture.data.valid -or -not (Test-Path -LiteralPath $refreshedFixture.data.backupPath -PathType Leaf)) { throw 'Guarded fixture refresh did not preserve and verify the manifest.' }
    if ($refreshedFixture.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$refreshedFixture.data.approval.oneShotReason)) { throw 'Shared fixture replacement was not explicitly classified as a one-shot approval.' }
    $iniBeforeCas = [IO.File]::ReadAllBytes($ini)
    $casRejected = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label cas-race -SavePolicy FreshGame -InternalTestFailurePoint selected-profile-before-cas -Confirm:$false -NoExit | ConvertFrom-Json
    $iniAfterCas = [IO.File]::ReadAllBytes($ini)
    if ($casRejected.ok -or $casRejected.errors[0] -notmatch 'changed after planning and before replacement' -or [Convert]::ToBase64String($iniAfterCas) -ceq [Convert]::ToBase64String($iniBeforeCas) -or [Text.Encoding]::UTF8.GetString($iniAfterCas) -notmatch 'injected concurrent drift') { throw "Selected-profile mutation did not reject immediate preimage drift while preserving the live external bytes: $($casRejected | ConvertTo-Json -Depth 12 -Compress)" }
    [IO.File]::WriteAllBytes($ini, $iniBeforeCas)
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label weather -SavePolicy FreshGame -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw "Workspace creation failed: $($created | ConvertTo-Json -Depth 12 -Compress)" }
    if ($created.data.configuration.source -ne 'explicit' -or [IO.Path]::GetFullPath([string]$created.data.configuration.path) -ne [IO.Path]::GetFullPath($configPath)) { throw 'Workspace result did not expose exact configuration resolution provenance.' }
    if ($created.data.ownerTaskId -ne $taskId -or (Get-Content -LiteralPath $ini -Raw) -notmatch ('selected_profile=@ByteArray\(' + [regex]::Escape([string]$created.data.profileName) + '\)')) { throw 'Creation did not bind and select the task-owned workspace.' }
    if ($created.data.profileName -ne $created.data.profile -or $created.data.profileDirectory -ne $created.data.profilePath -or $created.data.modListPath -ne (Join-Path $created.data.profilePath 'modlist.txt')) { throw 'Workspace profile identity fields are not explicit and canonical.' }
    if ($created.data.runtimeOutput.mode -ne 'mo2-overwrite-output' -or -not (Test-Path -LiteralPath $created.data.runtimeOutput.ownerMarkerPath -PathType Leaf)) { throw 'Workspace did not bind its exact MO2 Overwrite owner marker.' }
    $runtimeBackupRoot = [string]$created.data.runtimeOutput.backupPath
    foreach ($relativeBackup in @('hashes', 'previous\shader.bin')) {
        $runtimeBackup = Join-Path $runtimeBackupRoot $relativeBackup
        $sourceBackup = Join-Path (Join-Path $synthesisMod 'backup') $relativeBackup
        if (-not (Test-Path -LiteralPath $runtimeBackup -PathType Leaf) -or (Get-FileHash -LiteralPath $runtimeBackup -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $sourceBackup -Algorithm SHA256).Hash) { throw "Workspace did not shadow generated backup file '$relativeBackup'." }
    }
    if ([int]$created.data.runtimeOutput.shadowReceipt.requiredProviderFiles -ne 2 -or [int]$created.data.runtimeOutput.shadowReceipt.copiedFiles -ne 2) { throw 'Workspace did not receipt the complete generated backup provider tree in Overwrite.' }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeBackupRoot 'preexisting.bin') -PathType Leaf)) { throw 'Workspace did not preserve the pre-task Overwrite backup file.' }
    $taskSettings = Get-Content -LiteralPath (Join-Path $created.data.profilePath 'settings.ini') -Raw
    if ($taskSettings -match '(?im)^(Test|Synthesis)=') { throw 'Workspace retained a custom-overwrite mapping that diverts generated output away from MO2 Overwrite.' }
    if (@(Get-Content -LiteralPath $created.data.modListPath | Where-Object { $_ -like '+Codex Runtime Output -*' }).Count -ne 0) { throw 'Workspace registered a runtime-output mod instead of using MO2 Overwrite.' }
    $initialIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if (-not $initialIsolation.ok -or -not $initialIsolation.backupVerification.ok -or [int]$initialIsolation.backupVerification.requiredProviderFiles -ne 2) { throw "Fresh workspace Overwrite isolation was not valid and unprepared: $($initialIsolation | ConvertTo-Json -Depth 12 -Compress)" }
    $shadowedNestedBackup = Join-Path $runtimeBackupRoot 'previous\shader.bin'
    $shadowedNestedBackupBytes = [IO.File]::ReadAllBytes($shadowedNestedBackup)
    Remove-Item -LiteralPath $shadowedNestedBackup -Force
    $missingBackupIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if ($missingBackupIsolation.ok -or @($missingBackupIsolation.errors | Where-Object { $_ -match 'Overwrite backup lacks 1 enabled-provider path' }).Count -ne 1) { throw 'MO2 backup verification did not reject a missing nested provider shadow.' }
    [IO.File]::WriteAllBytes($shadowedNestedBackup, $shadowedNestedBackupBytes)
    $lateLowerBackup = Join-Path $synthesisMod 'backup\latest-build\new-area.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $lateLowerBackup) -Force | Out-Null
    'late-lower-backup' | Set-Content -LiteralPath $lateLowerBackup -Encoding utf8
    $lateBackupIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if ($lateBackupIsolation.ok -or @($lateBackupIsolation.errors | Where-Object { $_ -match 'backup receipt no longer covers the current enabled-provider inventory' }).Count -ne 1) { throw 'MO2 backup verification did not reject provider drift.' }
    Remove-Item -LiteralPath $lateLowerBackup -Force
    $taskOnlyBackup = Join-Path $runtimeBackupRoot 'task-only\new-area.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskOnlyBackup) -Force | Out-Null
    'generated-during-task' | Set-Content -LiteralPath $taskOnlyBackup -Encoding utf8
    $changedBackupBeforeLaunch = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if ($changedBackupBeforeLaunch.ok -or @($changedBackupBeforeLaunch.errors | Where-Object { $_ -match 'Overwrite backup changed after workspace creation and before its first launch' }).Count -ne 1) { throw 'MO2 backup verification did not reject unexplained pre-launch output drift.' }
    $backupGrowthIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -AllowPreparedCacheGrowth
    if (-not $backupGrowthIsolation.ok -or -not $backupGrowthIsolation.backupVerification.allowPreparedCacheGrowth) { throw 'MO2 backup verification did not permit isolated growth for a retained game cycle.' }
    Remove-Item -LiteralPath $taskOnlyBackup -Force
    $unpreparedSession = Invoke-MO2Prepare -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -Label fixture-unprepared -WhatIf
    if ($unpreparedSession.ok -or @($unpreparedSession.errors | Where-Object { $_ -match 'shader-cache prepare plan' }).Count -ne 1) { throw 'MO2 prepare did not fail closed before the bound cache plan existed.' }
    $catalogEntry = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheCatalog.ps1'
    $catalogRoot = Join-Path $fixture 'shader-cache-catalog'
    $shaderSourceSha256 = [string]::new([char]'A', 64)
    $preparedCache = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $created.data.runtimeOutput.cachePath -ProfilePath $created.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $created.data.runtimeOutput.cacheEvidenceDirectory -ShaderCacheAbi fixture-v1 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    $preparedIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if (-not $preparedCache.ok -or -not $preparedIsolation.ok -or -not $preparedIsolation.cachePlan.verification.ok -or [int]$preparedIsolation.cachePlan.verification.requiredProviderFiles -ne 1) { throw "Prepared Overwrite provider-shadow verification failed. Prepare: $($preparedCache | ConvertTo-Json -Depth 20 -Compress) Isolation: $($preparedIsolation | ConvertTo-Json -Depth 20 -Compress)" }
    $shadowedLowerCache = Join-Path $created.data.runtimeOutput.cachePath 'Lighting\later-area.pso'
    $shadowedLowerBytes = [IO.File]::ReadAllBytes($shadowedLowerCache)
    Remove-Item -LiteralPath $shadowedLowerCache -Force
    $missingShadowIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($missingShadowIsolation.ok -or @($missingShadowIsolation.errors | Where-Object { $_ -match 'Overwrite ShaderCache lacks 1 enabled-provider path' }).Count -ne 1) { throw 'MO2 cache verification did not reject a missing provider shadow.' }
    [IO.File]::WriteAllBytes($shadowedLowerCache, $shadowedLowerBytes)
    $lateLowerCache = Join-Path $synthesisMod 'ShaderCache\Lighting\second-area.pso'
    'late-lower-provider' | Set-Content -LiteralPath $lateLowerCache -Encoding utf8
    $lateLowerIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($lateLowerIsolation.ok -or @($lateLowerIsolation.errors | Where-Object { $_ -match 'receipt no longer covers the current enabled-provider inventory' }).Count -ne 1) { throw 'MO2 cache verification did not reject provider drift after prepare.' }
    Remove-Item -LiteralPath $lateLowerCache -Force
    $taskOnlyCache = Join-Path $created.data.runtimeOutput.cachePath 'TaskOnly\new-area.pso'
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskOnlyCache) -Force | Out-Null
    'compiled-during-task' | Set-Content -LiteralPath $taskOnlyCache -Encoding utf8
    $changedBeforeLaunch = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($changedBeforeLaunch.ok -or @($changedBeforeLaunch.errors | Where-Object { $_ -match 'changed after prepare and before its first launch' }).Count -ne 1) { throw 'MO2 cache verification did not reject unexplained pre-launch task-cache drift.' }
    $growthIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache -AllowPreparedCacheGrowth
    if (-not $growthIsolation.ok -or -not $growthIsolation.cachePlan.verification.allowPreparedCacheGrowth) { throw 'MO2 cache verification did not permit isolated cache growth for a retained game cycle.' }
    Remove-Item -LiteralPath $taskOnlyCache -Force
    $generatedCache = Join-Path $created.data.runtimeOutput.cachePath 'latest-build\generated-in-game.pso'
    New-Item -ItemType Directory -Path (Split-Path -Parent $generatedCache) -Force | Out-Null
    'generated-in-game' | Set-Content -LiteralPath $generatedCache -Encoding utf8
    $completedCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $created.data.runtimeOutput.cachePath -EvidenceDirectory $created.data.runtimeOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    if (-not $completedCache.ok -or $completedCache.state -ne 'complete') { throw "Prepared provider-shadow transaction did not complete: $($completedCache | ConvertTo-Json -Depth 20 -Compress)" }
    $taskGeneratedBackup = Join-Path $runtimeBackupRoot 'latest-build\generated-in-game.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskGeneratedBackup) -Force | Out-Null
    'generated-in-game' | Set-Content -LiteralPath $taskGeneratedBackup -Encoding utf8
    $completedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $completedOutput.ok -or $completedOutput.state -ne 'complete' -or (Test-Path -LiteralPath $created.data.runtimeOutput.ownerMarkerPath -PathType Leaf)) { throw "Workspace Overwrite output did not complete and release its owner marker: $($completedOutput | ConvertTo-Json -Depth 16 -Compress)" }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeBackupRoot 'preexisting.bin') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $runtimeBackupRoot 'hashes') -PathType Leaf)) { throw 'Backup completion did not restore the exact pre-task MO2 Overwrite tree.' }
    $ordinaryCopied = Join-Path $created.data.profilePath 'saves\ordinary.ess'
    if (-not (Test-Path -LiteralPath $ordinaryCopied -PathType Leaf) -or (Get-FileHash -LiteralPath $ordinaryCopied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Algorithm SHA256).Hash) { throw 'Workspace did not copy the complete stable-source saves tree.' }
    if (-not $created.data.inheritedSaves -or $created.data.sourceSaveSnapshot.sha256 -ne $created.data.profileSaveSnapshot.sha256 -or $created.data.sourceSaveSnapshot.fileCount -ne 3) { throw 'Workspace did not report a verified inherited-save snapshot.' }
    if (-not $created.data.copiedWorldEntrySave -or -not $created.data.sourceIntegrity.integrityVerified -or $created.data.sourceIntegrity.runtimeQualified -or [string]::IsNullOrWhiteSpace([string]$created.data.sourceIntegrity.cloneVerifiedUtc) -or $null -ne $created.data.sourceIntegrity.runtimeQualificationEvidence -or $created.data.worldEntryFixture.id -ne 'interior' -or $null -ne $created.data.saveFixture) { throw 'Ordinary fresh creation did not preserve the integrity-verified world-entry baseline independently of SavePolicy.' }
    $workspaceControlRoot = Join-Path $sessions 'workspaces'
    $partialProfile = Join-Path $profiles 'Codex interrupted create fixture'
    New-Item -ItemType Directory -Path $partialProfile -Force | Out-Null
    'partial-clone' | Set-Content -LiteralPath (Join-Path $partialProfile 'modlist.txt') -Encoding utf8
    $partialManifest = Join-Path $workspaceControlRoot 'interrupted-create.workspace.json'
    $partialJournal = Join-Path $workspaceControlRoot 'interrupted-create.creation.journal.json'
    [ordered]@{contractVersion='2.0.0';operation='create';phase='profile-copy-uncommitted';workspaceId='interrupted-create';ownershipId='interrupted-owner';profilePath=$partialProfile;manifestPath=$partialManifest} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $partialJournal -Encoding utf8
    $recoveryList = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    $partialJournalResult = Get-Content -LiteralPath $partialJournal -Raw | ConvertFrom-Json
    if (-not $recoveryList.ok -or (Test-Path -LiteralPath $partialProfile) -or (Test-Path -LiteralPath $partialManifest) -or $partialJournalResult.phase -ne 'rolled-back') { throw 'Startup recovery did not remove and terminally record an interrupted workspace creation.' }
    $selectionJournalPath = [string]$created.data.selectedProfileTransaction.journalPath
    $selectionReceiptPath = [string]$created.data.selectedProfileTransaction.receiptPath
    $interruptedSelection = Get-Content -LiteralPath $selectionJournalPath -Raw | ConvertFrom-Json
    $interruptedSelection.phase = 'selection-applied-uncommitted'
    $interruptedSelection | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $selectionJournalPath -Encoding utf8
    Remove-Item -LiteralPath $selectionReceiptPath -Force
    $verified = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label verified -SavePolicy VerifiedFixture -Confirm:$false | ConvertFrom-Json
    if (-not $verified.ok -or -not $verified.data.copiedVerifiedSaves -or $verified.data.saveFixture.id -ne 'interior') { throw 'Verified fixture workspace was not created from the configured default.' }
    $recoveredSelection = Get-Content -LiteralPath $selectionJournalPath -Raw | ConvertFrom-Json
    if ($recoveredSelection.phase -ne 'recovered-committed' -or -not (Test-Path -LiteralPath $selectionReceiptPath -PathType Leaf)) { throw 'A subsequent transaction did not discover and finalize the interrupted selected-profile journal.' }
    foreach ($name in @('Save2_KnownGood.ess', 'Save2_KnownGood.skse')) {
        $copied = Join-Path $verified.data.profilePath (Join-Path 'saves' $name)
        $sourceSave = Join-Path $source (Join-Path 'saves' $name)
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sourceSave -Algorithm SHA256).Hash) { throw "Verified fixture did not copy exact save file: $name" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $verified.data.profilePath 'saves\ordinary.ess') -PathType Leaf)) { throw 'Verified fixture workspace did not retain the complete source save set.' }
    $verifiedPreparedCache = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $verified.data.runtimeOutput.cachePath -ProfilePath $verified.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $verified.data.runtimeOutput.cacheEvidenceDirectory -ShaderCacheAbi fixture-v1 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    $verifiedCompletedCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $verified.data.runtimeOutput.cachePath -EvidenceDirectory $verified.data.runtimeOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    $verifiedCompletedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $verifiedPreparedCache.ok -or -not $verifiedCompletedCache.ok -or -not $verifiedCompletedOutput.ok) { throw 'Verified fixture workspace output transactions did not complete.' }
    $createdMod = & $entry create-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -Confirm:$false | ConvertFrom-Json
    if (-not $createdMod.ok -or $createdMod.state -ne 'mod-created') { throw 'Workspace did not create a separately owned mod directory.' }
    $newMod = [string]$createdMod.data.modDirectory
    New-Item -ItemType Directory -Path (Join-Path $newMod 'SKSE\Plugins') -Force | Out-Null
    'task-provider' | Set-Content -LiteralPath (Join-Path $newMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    $winningPathsFile = Join-Path $fixture 'winning-paths.txt'
    "SKSE\Plugins\Example.dll" | Set-Content -LiteralPath $winningPathsFile -Encoding utf8
    $registered = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -ModDirectory $newMod -WinningPathsFile $winningPathsFile -Confirm:$false | ConvertFrom-Json
    if (-not $registered.ok -or -not $registered.data.registration.enabled) { throw "Owned winning mod registration failed: $($registered | ConvertTo-Json -Depth 8 -Compress)" }
    $winnerReceipt = Get-Content -LiteralPath $registered.data.registration.receiptPath -Raw | ConvertFrom-Json
    if (-not $winnerReceipt.winnerProof.verified -or $winnerReceipt.relativeToMod -ne 'Loader') { throw 'Workspace registration did not prove the task DLL wins.' }
    $ensured = & $entry ensure-mod-wins -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -WinningPaths 'SKSE\Plugins\Example.dll' -Confirm:$false | ConvertFrom-Json
    if (-not $ensured.ok -or $ensured.state -ne 'winner-verified') { throw 'Workspace could not re-verify its task-owned winning mod.' }
    $longNames = @('Codex CSX common prefix extending beyond thirty two characters alpha', 'Codex CSX common prefix extending beyond thirty two characters beta')
    $longRegistrations = @()
    foreach ($longName in $longNames) {
        $longCreated = & $entry create-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName $longName -Confirm:$false | ConvertFrom-Json
        $longRegistrations += ,(& $entry register-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName $longName -ModDirectory $longCreated.data.modDirectory -Confirm:$false | ConvertFrom-Json)
    }
    $longEvidence = @($longRegistrations | ForEach-Object { Split-Path -Parent ([string]$_.data.registration.receiptPath) })
    if (@($longRegistrations | Where-Object { -not $_.ok }).Count -ne 0 -or $longEvidence[0] -eq $longEvidence[1]) { throw 'Long common-prefix mod names did not receive distinct collision-resistant registration evidence.' }
    $preexisting = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName Loader -ModDirectory $loaderMod -NoExit -Confirm:$false | ConvertFrom-Json
    if ($preexisting.ok) { throw 'Workspace claimed a pre-existing mod.' }
    'retained-profile-state' | Set-Content -LiteralPath (Join-Path $created.data.profilePath 'task-state.txt') -Encoding utf8
    $unsafeRelease = & $entry release -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
    if ($unsafeRelease.ok -or $unsafeRelease.errors[0] -notmatch 'intentionally unavailable' -or -not (Test-Path -LiteralPath $created.data.profilePath) -or -not (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'task-state.txt'))) { throw 'Deprecated workspace release did not fail closed while preserving retained task state.' }
    $listed = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    if (-not $listed.ok -or $listed.data.count -ne 2) { throw 'Task workspace discovery did not list both retained profiles.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    if (-not $releasedAccess.ok -or -not (Test-Path -LiteralPath $created.data.profilePath)) { throw 'Yielding MO2 access did not preserve the retained task profile.' }
    $laterSharedMod = Join-Path $mods 'Later Shared Mod'; New-Item -ItemType Directory -Path $laterSharedMod -Force | Out-Null
    $nextAccess = Invoke-MO2RequestAccess -Config $config -Label fixture-resume; $nextAccessId = [string]$nextAccess.data.access.accessId
    $wrongOwner = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId 'different-task' -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
    if ($wrongOwner.ok -or $wrongOwner.errors[0] -notmatch 'different task') { throw 'A different task identity was allowed to resume the retained workspace.' }
    $resumed = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $resumed.ok -or $resumed.state -ne 'workspace-resumed' -or $resumed.data.accessId -ne $nextAccessId -or -not (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'task-state.txt'))) { throw "Retained workspace was not rebound without losing task state: $($resumed | ConvertTo-Json -Depth 12 -Compress)" }
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch ('selected_profile=@ByteArray\(' + [regex]::Escape([string]$created.data.profileName) + '\)')) { throw 'Resume did not select the retained task profile.' }
    $resumeJournal = Get-ChildItem -LiteralPath $workspaceControlRoot -Filter ($created.data.workspaceId + '.resume.*.journal.json') -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $resumeJournalData = Get-Content -LiteralPath $resumeJournal.FullName -Raw | ConvertFrom-Json
    if ($resumeJournalData.phase -ne 'committed' -or -not (Test-Path -LiteralPath $resumeJournalData.manifestPreimagePath -PathType Leaf) -or [string]::IsNullOrWhiteSpace([string]$resumeJournalData.selectedProfileJournalPath)) { throw 'Committed resume did not retain a durable manifest preimage and selected-profile journal link.' }
    $resumeManifestPath = [string]$resumeJournalData.manifestPath
    $resumePreimageBytes = [IO.File]::ReadAllBytes($resumeManifestPath)
    $resumePreimageHash = (Get-FileHash -LiteralPath $resumeManifestPath -Algorithm SHA256).Hash
    $resumeRecoveryId = [guid]::NewGuid().ToString('N')
    $resumeRecoveryPreimage = Join-Path $workspaceControlRoot ($created.data.workspaceId + '.resume.' + $resumeRecoveryId + '.manifest-preimage.bin')
    [IO.File]::WriteAllBytes($resumeRecoveryPreimage, $resumePreimageBytes)
    $resumeDrift = Get-Content -LiteralPath $resumeManifestPath -Raw | ConvertFrom-Json
    $resumeDrift.accessId = 'interrupted-resume-access'
    $resumeDrift | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resumeManifestPath -Encoding utf8
    $resumeRecoveryJournal = Join-Path $workspaceControlRoot ($created.data.workspaceId + '.resume.' + $resumeRecoveryId + '.journal.json')
    [ordered]@{contractVersion='2.0.0';operation='resume';phase='manifest-write-uncommitted';operationId=$resumeRecoveryId;workspaceId=$created.data.workspaceId;ownershipId=$created.data.ownershipId;manifestPath=$resumeManifestPath;manifestPreimagePath=$resumeRecoveryPreimage;manifestPreimageSha256=$resumePreimageHash;profilePath=$created.data.profilePath} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resumeRecoveryJournal -Encoding utf8
    $null = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    $resumeRecoveredJournal = Get-Content -LiteralPath $resumeRecoveryJournal -Raw | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath $resumeManifestPath -Algorithm SHA256).Hash -cne $resumePreimageHash -or $resumeRecoveredJournal.phase -ne 'rolled-back') { throw 'Startup recovery did not restore the exact persisted resume manifest preimage.' }
    $lateClaim = & $entry register-mod -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -ModName 'Later Shared Mod' -ModDirectory $laterSharedMod -NoExit -Confirm:$false | ConvertFrom-Json
    if ($lateClaim.ok -or $lateClaim.errors[0] -notmatch 'protected shared mod') { throw 'Resume did not protect a shared mod added after workspace creation.' }
    $resumedVerified = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $resumedVerified.ok) { throw 'Second retained workspace could not be explicitly resumed.' }
    $releasedVerified = & $entry retire -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $releasedVerified.ok -or (Test-Path -LiteralPath $verified.data.profilePath)) { throw "Verified fixture workspace retirement failed: $($releasedVerified | ConvertTo-Json -Depth 12 -Compress)" }
    $resumedAgain = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $resumedAgain.ok) { throw 'Original retained workspace could not be reselected after another workspace.' }
    $retireManifestPath = Join-Path $workspaceControlRoot ($created.data.workspaceId + '.json')
    $retirePreimageBytes = [IO.File]::ReadAllBytes($retireManifestPath)
    $retirePreimageHash = (Get-FileHash -LiteralPath $retireManifestPath -Algorithm SHA256).Hash
    $retireRecoveryId = [guid]::NewGuid().ToString('N')
    $retirePreimagePath = Join-Path $workspaceControlRoot ($created.data.workspaceId + '.retire.' + $retireRecoveryId + '.manifest-preimage.bin')
    [IO.File]::WriteAllBytes($retirePreimagePath, $retirePreimageBytes)
    $profileQuarantine = Join-Path $profiles ('.codex-retired-' + $created.data.workspaceId + '-' + $retireRecoveryId)
    $modQuarantine = Join-Path $mods ('.codex-retired-Owned Test Mod-' + $retireRecoveryId)
    Move-Item -LiteralPath $created.data.profilePath -Destination $profileQuarantine
    Move-Item -LiteralPath $newMod -Destination $modQuarantine
    $retireRecoveryJournal = Join-Path $workspaceControlRoot ($created.data.workspaceId + '.retire.' + $retireRecoveryId + '.journal.json')
    [ordered]@{contractVersion='2.0.0';operation='retire';phase='profile-move-uncommitted';operationId=$retireRecoveryId;workspaceId=$created.data.workspaceId;ownershipId=$created.data.ownershipId;manifestPath=$retireManifestPath;manifestPreimagePath=$retirePreimagePath;manifestPreimageSha256=$retirePreimageHash;profilePath=$created.data.profilePath;profileQuarantine=$profileQuarantine;modMoves=@([ordered]@{source=$newMod;quarantine=$modQuarantine;moved=$true})} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $retireRecoveryJournal -Encoding utf8
    $null = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    $retireRecoveredJournal = Get-Content -LiteralPath $retireRecoveryJournal -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $created.data.profilePath -PathType Container) -or -not (Test-Path -LiteralPath $newMod -PathType Container) -or $retireRecoveredJournal.phase -ne 'rolled-back' -or (Get-FileHash -LiteralPath $retireManifestPath -Algorithm SHA256).Hash -cne $retirePreimageHash) { throw 'Startup recovery did not restore an interrupted retirement profile, mod, and exact manifest preimage.' }
    $released = & $entry retire -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -Confirm:$false | ConvertFrom-Json
    if (-not $released.ok -or (Test-Path -LiteralPath $created.data.profilePath) -or (Test-Path -LiteralPath $newMod)) { throw "Workspace cleanup did not remove only its owned artifacts: $($released | ConvertTo-Json -Depth 12 -Compress)" }
    $preservedCache = [string]$released.data.runtimeOutputPreservation.cache.preservedPath
    $preservedBackup = [string]$released.data.runtimeOutputPreservation.backup.preservedPath
    if (-not $released.data.runtimeOutputPreservation.preserved -or -not (Test-Path -LiteralPath (Join-Path $preservedCache 'latest-build\generated-in-game.pso') -PathType Leaf)) { throw 'Workspace retirement did not retain generated ShaderCache output evidence.' }
    if (-not (Test-Path -LiteralPath (Join-Path $preservedBackup 'hashes') -PathType Leaf) -or (Get-FileHash -LiteralPath (Join-Path $preservedBackup 'hashes') -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $synthesisMod 'backup\hashes') -Algorithm SHA256).Hash) { throw 'Workspace retirement did not preserve the generated backup tree byte-identically.' }
    if (-not (Test-Path -LiteralPath (Join-Path $preservedBackup 'previous\shader.bin') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $preservedBackup 'latest-build\generated-in-game.bin') -PathType Leaf)) { throw 'Workspace retirement did not preserve nested provider and in-game backup output.' }
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch 'selected_profile=@ByteArray\(Mad God Stable\)') { throw 'Workspace release did not select the stable source before deleting the task profile.' }
    if (-not (Test-Path -LiteralPath $released.data.selectedProfileRelease.backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $released.data.selectedProfileRelease.receiptPath -PathType Leaf)) { throw 'Workspace release did not retain exact INI backup and receipt evidence.' }
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $loaderMod)) { throw 'Workspace cleanup damaged stable state.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $nextAccessId
    if (-not $releasedAccess.ok) { throw 'Resumed access release failed.' }
    [pscustomobject]@{ok=$true; assertions=90; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally {
    $env:CSX_MO2_PROFILE_CONTROL_ROOT = $priorProfileControlRoot
    $env:CSX_SHADER_CACHE_CONTROL_ROOT = $priorShaderCacheControlRoot
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
