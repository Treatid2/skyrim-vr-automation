# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param([switch]$DiscoveryOnly)

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-workspace-control-' + [guid]::NewGuid().ToString('N'))
$taskId = 'codex-test-task-001'
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
    $csxReleaseMod = Join-Path $mods '[NoDelete] CSX AIO Local Release'
    $csxDevBenchMod = Join-Path $mods '[NoDelete] CSX AIO Local DevBench'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $loaderMod 'SKSE\Plugins'), $csxReleaseMod, $csxDevBenchMod, (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    @('+Loader', '+[NoDelete] CSX AIO Local Release', '-[NoDelete] CSX AIO Local DevBench') | Set-Content -LiteralPath (Join-Path $source 'modlist.txt') -Encoding utf8
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    'ordinary-base-save' | Set-Content -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Encoding utf8
    'known-good-save' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.ess') -Encoding utf8
    'known-good-cosave' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.skse') -Encoding utf8
    'existing-provider' | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    foreach ($cachePath in @(
        (Join-Path $mo2 'overwrite\ShaderCache'),
        (Join-Path $mo2 'overwrite\ShaderCache.Previous'),
        (Join-Path $mo2 'overwrite\Root\Data\ShaderCache.Swap')
    )) {
        New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
        ('compiled-' + [IO.Path]::GetFileName($cachePath)) | Set-Content -LiteralPath (Join-Path $cachePath 'fixture.bin') -Encoding utf8
    }
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $ini = Join-Path $mo2 'ModOrganizer.ini'
    [IO.File]::WriteAllText(
        $ini,
        "[General]`r`nselected_profile=@ByteArray(Codex)`r`n[customExecutables]`r`n1\title=@ByteArray(Test)`r`n1\binary=@ByteArray($loader)`r`n1\workingDirectory=@ByteArray($fixture)`r`n",
        [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $fixture 'config.json'; $lock = Join-Path $sessions 'lock.json'
    $fixtureManifestPath = Join-Path $fixture 'known-good-saves.json'
    $localWorkCatalogPath = Join-Path $fixture 'local-work-mods.json'
    [ordered]@{
        contractVersion = '1.0.0'
        candidates = @(
            [ordered]@{ id='csx-aio-local-release'; label='CSX AIO local (DevBench off)'; description='Release-equivalent local CSX build without development bridges.'; modName='[NoDelete] CSX AIO Local Release'; exclusionGroup='csx-aio'; variant='devbench-off'; capabilities=@('csx-aio'); metadata=[ordered]@{devBenchBridgeEnabled=$false;releaseEquivalent=$true} },
            [ordered]@{ id='csx-aio-local-devbench'; label='CSX AIO local (DevBench on)'; description='Local CSX build with DevBench bridges for automation.'; modName='[NoDelete] CSX AIO Local DevBench'; exclusionGroup='csx-aio'; variant='devbench-on'; capabilities=@('csx-aio','devbench-api'); metadata=[ordered]@{devBenchBridgeEnabled=$true;releaseEquivalent=$false} }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $localWorkCatalogPath -Encoding utf8
    $saveFiles = @('Save2_KnownGood.ess', 'Save2_KnownGood.skse') | ForEach-Object {
        $path = Join-Path $source (Join-Path 'saves' $_)
        [ordered]@{ relativePath = $_; bytes = [long](Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    [ordered]@{ contractVersion='1.0.0'; sourceProfile='Mad God Stable'; profileFingerprintSha256=(Get-TestProfileFingerprint $source); defaultFixtureId='interior'; fixtures=@([ordered]@{id='interior';label='Known-good interior';location='TestCell';loadName='Save2_KnownGood';files=$saveFiles}) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding utf8
    [ordered]@{
        contractVersion='0.4.0'; machine='fixture'; mo2=[ordered]@{root=$mo2;executable=$mo2Exe;ini=$ini;profilesDirectory=$profiles;modsDirectory=$mods;overwriteDirectory=(Join-Path $mo2 'overwrite');logsDirectory=(Join-Path $mo2 'logs');rootBuilderDefinitions=@();rootBuilderDataDirectory=(Join-Path $mo2 'rb');processNames=@('WorkspaceImpossibleMO2');gameProcessNames=@('WorkspaceImpossibleGame');runtimeProcessNames=@()};
        defaults=[ordered]@{profile='Mad God Stable';testProfileSource='Mad God Stable';newGameFixtureManifest=$fixtureManifestPath;localWorkModCatalog=$localWorkCatalogPath;executable='Test'};storage=[ordered]@{sessionStaging=$sessions;archive=(Join-Path $fixture 'archive')};limits=[ordered]@{maxEnumeratedFiles=100;overwriteWarningFiles=10;overwriteBlockFiles=50;overwriteWarningBytes=1024;overwriteBlockBytes=4096;launchPendingGraceSeconds=30};session=[ordered]@{lockFile=$lock}
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
    $localWorkMods = & $entry list-local-work-mods -ConfigPath $configPath -Compact | ConvertFrom-Json
    if (-not $localWorkMods.ok -or $localWorkMods.state -ne 'local-work-mods-found' -or $localWorkMods.data.availableCount -ne 2) { throw 'Local-work mod discovery did not expose both CSX AIO variants.' }
    $releaseCandidate = @($localWorkMods.data.catalog.candidates | Where-Object id -eq 'csx-aio-local-release')[0]
    $devBenchCandidate = @($localWorkMods.data.catalog.candidates | Where-Object id -eq 'csx-aio-local-devbench')[0]
    if (-not $releaseCandidate.available -or $releaseCandidate.metadata.devBenchBridgeEnabled -or -not $releaseCandidate.metadata.releaseEquivalent -or -not $devBenchCandidate.available -or -not $devBenchCandidate.metadata.devBenchBridgeEnabled) { throw 'CSX AIO candidate metadata did not distinguish release and DevBench builds.' }
    if ($localWorkMods.data.approval.escalationUsuallyRequired -or -not $localWorkMods.data.approval.reusableApprovalEligible) { throw 'Local-work mod discovery was not classified as read-only and reusable.' }
    $noLocalWorkPath = Join-Path $fixture 'config-no-local-work.json'
    $noLocalWork = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $noLocalWork.defaults.PSObject.Properties.Remove('localWorkModCatalog')
    $noLocalWork | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $noLocalWorkPath -Encoding utf8
    $noLocalWorkStatus = & $entry list-local-work-mods -ConfigPath $noLocalWorkPath -Compact | ConvertFrom-Json
    if (-not $noLocalWorkStatus.ok -or $noLocalWorkStatus.state -ne 'catalog-not-configured' -or $noLocalWorkStatus.data.availableCount -ne 0) { throw 'A missing optional catalog did not preserve the modlist-only discovery contract.' }
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
    $blockedCreate = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label blocked-by-cache -SavePolicy FreshGame -Confirm:$false -NoExit | ConvertFrom-Json
    if ($blockedCreate.ok -or $blockedCreate.errors[0] -notmatch 'prepare-source') { throw 'Workspace creation did not block unmanaged ShaderCache folders in overwrite.' }
    $prepared = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $prepared.ok -or $prepared.state -ne 'migrated' -or @($prepared.data.movedDirectories).Count -ne 3) { throw "Stable source cache preparation failed: $($prepared | ConvertTo-Json -Depth 8 -Compress)" }
    if ($prepared.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$prepared.data.approval.oneShotReason)) { throw 'Shader-cache migration was not classified as one-shot.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $mo2 'overwrite') -Directory -Recurse -Force | Where-Object Name -Match '^(?i:ShaderCache)(?:[.]|$)').Count -ne 0) { throw 'ShaderCache directories remained in overwrite after preparation.' }
    if ((Get-Content -LiteralPath (Join-Path $source 'modlist.txt') -Raw) -notmatch ('(?m)^\+' + [regex]::Escape([string]$prepared.data.modName) + '\r?$')) { throw 'Migrated shader-cache mod was not enabled in the stable source.' }
    foreach ($move in @($prepared.data.movedDirectories)) { if (-not (Test-Path -LiteralPath ([string]$move.destinationPath) -PathType Container)) { throw "Migrated ShaderCache destination is missing: $($move.destinationPath)" } }
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
    if ($casRejected.ok -or $casRejected.errors[0] -notmatch 'changed after planning and before replacement' -or [Convert]::ToBase64String($iniAfterCas) -ceq [Convert]::ToBase64String($iniBeforeCas) -or [Text.Encoding]::UTF8.GetString($iniAfterCas) -notmatch 'injected concurrent drift') { throw 'Selected-profile mutation did not reject immediate preimage drift while preserving the live external bytes.' }
    [IO.File]::WriteAllBytes($ini, $iniBeforeCas)
    $conflictingSelection = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label conflicting -SavePolicy FreshGame -WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModId @('csx-aio-local-release','csx-aio-local-devbench') -Confirm:$false -NoExit | ConvertFrom-Json
    if ($conflictingSelection.ok -or $conflictingSelection.errors[0] -notmatch 'Mutually exclusive') { throw 'Workspace creation accepted mutually exclusive CSX AIO variants.' }
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label weather -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw "Workspace creation failed: $($created | ConvertTo-Json -Depth 12 -Compress)" }
    if ($created.data.configuration.source -ne 'explicit' -or [IO.Path]::GetFullPath([string]$created.data.configuration.path) -ne [IO.Path]::GetFullPath($configPath)) { throw 'Workspace result did not expose exact configuration resolution provenance.' }
    if ($created.data.ownerTaskId -ne $taskId -or (Get-Content -LiteralPath $ini -Raw) -notmatch ('selected_profile=@ByteArray\(' + [regex]::Escape([string]$created.data.profileName) + '\)')) { throw 'Creation did not bind and select the task-owned workspace.' }
    if ($created.data.profileName -ne $created.data.profile -or $created.data.profileDirectory -ne $created.data.profilePath -or $created.data.modListPath -ne (Join-Path $created.data.profilePath 'modlist.txt')) { throw 'Workspace profile identity fields are not explicit and canonical.' }
    $ordinaryCopied = Join-Path $created.data.profilePath 'saves\ordinary.ess'
    if (-not (Test-Path -LiteralPath $ordinaryCopied -PathType Leaf) -or (Get-FileHash -LiteralPath $ordinaryCopied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Algorithm SHA256).Hash) { throw 'Workspace did not copy the complete stable-source saves tree.' }
    if (-not $created.data.inheritedSaves -or $created.data.sourceSaveSnapshot.sha256 -ne $created.data.profileSaveSnapshot.sha256 -or $created.data.sourceSaveSnapshot.fileCount -ne 3) { throw 'Workspace did not report a verified inherited-save snapshot.' }
    if (-not $created.data.copiedWorldEntrySave -or -not $created.data.sourceIntegrity.integrityVerified -or $created.data.sourceIntegrity.runtimeQualified -or [string]::IsNullOrWhiteSpace([string]$created.data.sourceIntegrity.cloneVerifiedUtc) -or $null -ne $created.data.sourceIntegrity.runtimeQualificationEvidence -or $created.data.worldEntryFixture.id -ne 'interior' -or $null -ne $created.data.saveFixture) { throw 'Ordinary fresh creation did not preserve the integrity-verified world-entry baseline independently of SavePolicy.' }
    $createdModList = Get-Content -LiteralPath $created.data.modListPath -Raw
    if ($created.data.localWorkMods.workspaceContent -ne 'Modlist' -or @($created.data.localWorkMods.requestedIds).Count -ne 0 -or $createdModList -notmatch '(?m)^-\[NoDelete\] CSX AIO Local Release\r?$' -or $createdModList -notmatch '(?m)^-\[NoDelete\] CSX AIO Local DevBench\r?$') { throw 'Modlist workspace did not disable every optional CSX AIO candidate.' }
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
    $localWorkIdsPath = Join-Path $fixture 'requested-local-work-mods.json'
    '["csx-aio-local-devbench"]' | Set-Content -LiteralPath $localWorkIdsPath -Encoding utf8
    $verified = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label verified -SavePolicy VerifiedFixture -WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModIdsFile $localWorkIdsPath -Confirm:$false | ConvertFrom-Json
    if (-not $verified.ok -or -not $verified.data.copiedVerifiedSaves -or $verified.data.saveFixture.id -ne 'interior') { throw 'Verified fixture workspace was not created from the configured default.' }
    $verifiedModList = Get-Content -LiteralPath $verified.data.modListPath -Raw
    if ($verified.data.localWorkMods.workspaceContent -ne 'ModlistPlusLocalWorkMods' -or @($verified.data.localWorkMods.requestedIds).Count -ne 1 -or $verified.data.localWorkMods.requestedIds[0] -ne 'csx-aio-local-devbench' -or $verifiedModList -notmatch '(?m)^-\[NoDelete\] CSX AIO Local Release\r?$' -or $verifiedModList -notmatch '(?m)^\+\[NoDelete\] CSX AIO Local DevBench\r?$') { throw 'Requested DevBench-enabled CSX AIO variant was not selected exclusively.' }
    $recoveredSelection = Get-Content -LiteralPath $selectionJournalPath -Raw | ConvertFrom-Json
    if ($recoveredSelection.phase -ne 'recovered-committed' -or -not (Test-Path -LiteralPath $selectionReceiptPath -PathType Leaf)) { throw 'A subsequent transaction did not discover and finalize the interrupted selected-profile journal.' }
    foreach ($name in @('Save2_KnownGood.ess', 'Save2_KnownGood.skse')) {
        $copied = Join-Path $verified.data.profilePath (Join-Path 'saves' $name)
        $sourceSave = Join-Path $source (Join-Path 'saves' $name)
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sourceSave -Algorithm SHA256).Hash) { throw "Verified fixture did not copy exact save file: $name" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $verified.data.profilePath 'saves\ordinary.ess') -PathType Leaf)) { throw 'Verified fixture workspace did not retain the complete source save set.' }
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
    $listedModlist = @($listed.data.workspaces | Where-Object workspaceId -eq $created.data.workspaceId)[0]
    $listedDevBench = @($listed.data.workspaces | Where-Object workspaceId -eq $verified.data.workspaceId)[0]
    if ($listedModlist.workspaceContent -ne 'Modlist' -or @($listedModlist.selectedLocalWorkModIds).Count -ne 0 -or $listedDevBench.workspaceContent -ne 'ModlistPlusLocalWorkMods' -or @($listedDevBench.selectedLocalWorkModIds)[0] -ne 'csx-aio-local-devbench') { throw 'Retained workspace discovery did not expose each original local-work selection.' }
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
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch 'selected_profile=@ByteArray\(Mad God Stable\)') { throw 'Workspace release did not select the stable source before deleting the task profile.' }
    if (-not (Test-Path -LiteralPath $released.data.selectedProfileRelease.backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $released.data.selectedProfileRelease.receiptPath -PathType Leaf)) { throw 'Workspace release did not retain exact INI backup and receipt evidence.' }
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $loaderMod)) { throw 'Workspace cleanup damaged stable state.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $nextAccessId
    if (-not $releasedAccess.ok) { throw 'Resumed access release failed.' }
    [pscustomobject]@{ok=$true; assertions=70; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
