# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param([switch]$DiscoveryOnly)

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$powerShell = (Get-Process -Id $PID).Path
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
    $ocuMod = Join-Path $mods 'OpenComposite Runtime Provider'
    $csxReleaseMod = Join-Path $mods '[NoDelete] CSX AIO Local Release'
    $csxDevBenchMod = Join-Path $mods '[NoDelete] CSX AIO Local DevBench'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $loaderMod 'SKSE\Plugins'), (Join-Path $synthesisMod 'ShaderCache\Lighting'), (Join-Path $synthesisMod 'backup\previous'), (Join-Path $ocuMod 'root'), (Join-Path $ocuMod 'SKSE\Plugins'), $csxReleaseMod, $csxDevBenchMod, (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $sourceModListPath = Join-Path $source 'modlist.txt'
    $sourceModListText = "+[NoDelete] CSX AIO Local Release`r`n+Loader`r`n+Synthesis Patch (SFW)`r`n+OpenComposite Runtime Provider`r`n-[NoDelete] CSX AIO Local DevBench`r`n"
    $sourceModListBytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.UTF8Encoding]::new($false).GetBytes($sourceModListText)
    [IO.File]::WriteAllBytes($sourceModListPath, $sourceModListBytes)
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    "[custom_overwrites]`r`nsYnThEsIs=Synthesis Patch (SFW)`r`n" | Set-Content -LiteralPath (Join-Path $source 'settings.ini') -Encoding utf8 -NoNewline
    'ordinary-base-save' | Set-Content -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Encoding utf8
    'known-good-save' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.ess') -Encoding utf8
    'known-good-cosave' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.skse') -Encoding utf8
    'existing-provider' | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    New-Item -ItemType File -Path (Join-Path $ocuMod 'root\openvr_api.dll'), (Join-Path $ocuMod 'SKSE\Plugins\OpenCompositeInput.dll') -Force | Out-Null
    'lower-provider-cache' | Set-Content -LiteralPath (Join-Path $synthesisMod 'ShaderCache\Lighting\later-area.pso') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $synthesisMod 'backup\hashes') -Encoding utf8 -NoNewline
    'older-generated-backup' | Set-Content -LiteralPath (Join-Path $synthesisMod 'backup\previous\shader.bin') -Encoding utf8
    foreach ($cachePath in @(
        (Join-Path $mo2 'overwrite\ShaderCache'),
        (Join-Path $mo2 'overwrite\ShaderCache.Previous'),
        (Join-Path $mo2 'overwrite\Root\Data\ShaderCache.Swap')
    )) {
        New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
        ('compiled-' + [IO.Path]::GetFileName($cachePath)) | Set-Content -LiteralPath (Join-Path $cachePath 'fixture.bin') -Encoding utf8
    }
    New-Item -ItemType Directory -Path (Join-Path $mo2 'overwrite\backup') -Force | Out-Null
    'pre-task-overwrite-backup' | Set-Content -LiteralPath (Join-Path $mo2 'overwrite\backup\preexisting.bin') -Encoding utf8
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $communityShadersPluginPath = Join-Path $loaderMod 'SKSE\Plugins\CommunityShaders.dll'
    $communityShadersPluginBytes = [byte[]](1, 4, 1, 5, 9, 2, 6)
    [IO.File]::WriteAllBytes($communityShadersPluginPath, $communityShadersPluginBytes)
    [pscustomobject]@{
        buildId = 'workspace-build-fixture'
        artifact = [pscustomobject]@{
            fileName = 'CommunityShaders.dll'
            sha256 = (Get-FileHash -LiteralPath $communityShadersPluginPath -Algorithm SHA256).Hash
            sizeBytes = $communityShadersPluginBytes.Length
        }
        identity = [pscustomobject]@{ shaderCache = [pscustomobject]@{ abiId = 'fixture-v1' } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\CSX.BuildManifest.json') -Encoding utf8
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
    $access = Invoke-MO2RequestAccess -Config $config -Label fixture -RuntimeRoute OCU; $accessId = [string]$access.data.access.accessId
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
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sourceModListPath)) -cne [Convert]::ToBase64String($sourceModListBytes)) { throw 'BOM-aware local-work discovery changed the stable source modlist bytes.' }
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
    $profileCountBeforeMissingContent = @(Get-ChildItem -LiteralPath $profiles -Directory -Force).Count
    $missingContentCreate = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label missing-content -SavePolicy FreshGame -Confirm:$false -NoExit | ConvertFrom-Json
    if ($missingContentCreate.ok -or $missingContentCreate.state -ne 'missing-workspace-content' -or $missingContentCreate.data.requiredParameter -ne 'WorkspaceContent' -or @(Get-ChildItem -LiteralPath $profiles -Directory -Force).Count -ne $profileCountBeforeMissingContent) { throw 'Workspace creation did not reject omitted content selection without profile side effects.' }
    $blockedCreate = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label blocked-by-cache -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
    if ($blockedCreate.ok -or $blockedCreate.errors[0] -notmatch 'prepare-source') { throw 'Workspace creation did not block unmanaged ShaderCache folders in overwrite.' }
    $migrationOverwrite = Join-Path $mo2 'overwrite'
    $migrationTarget = Join-Path $mo2 'overwrite-prepare-source-reparse-target'
    $sourceModListBeforeReparse = [IO.File]::ReadAllBytes((Join-Path $source 'modlist.txt'))
    $modCountBeforeReparse = @(Get-ChildItem -LiteralPath $mods -Directory -Force).Count
    Move-Item -LiteralPath $migrationOverwrite -Destination $migrationTarget -ErrorAction Stop
    try {
        New-Item -ItemType Junction -Path $migrationOverwrite -Target $migrationTarget -ErrorAction Stop | Out-Null
        $reparsePrepare = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact -NoExit | ConvertFrom-Json
        if ($reparsePrepare.ok -or @($reparsePrepare.errors | Where-Object { $_ -match 'reparse point' }).Count -ne 1 -or
            @(Get-ChildItem -LiteralPath $mods -Directory -Force).Count -ne $modCountBeforeReparse -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source 'modlist.txt'))) -cne [Convert]::ToBase64String($sourceModListBeforeReparse)) {
            throw 'prepare-source did not reject a reparse-point Overwrite root before moving caches or editing the stable profile.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $migrationOverwrite) { Remove-Item -LiteralPath $migrationOverwrite -Force }
        Move-Item -LiteralPath $migrationTarget -Destination $migrationOverwrite -ErrorAction Stop
    }
    $nestedReparseTarget = Join-Path $mo2 'overwrite-nested-reparse-target'
    $nestedReparsePath = Join-Path $migrationOverwrite 'aaa-reparse'
    New-Item -ItemType Directory -Path $nestedReparseTarget -Force | Out-Null
    try {
        New-Item -ItemType Junction -Path $nestedReparsePath -Target $nestedReparseTarget -ErrorAction Stop | Out-Null
        $nestedReparsePrepare = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact -NoExit | ConvertFrom-Json
        if ($nestedReparsePrepare.ok -or @($nestedReparsePrepare.errors | Where-Object { $_ -match 'reparse point' }).Count -ne 1 -or
            @(Get-ChildItem -LiteralPath $mods -Directory -Force).Count -ne $modCountBeforeReparse -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source 'modlist.txt'))) -cne [Convert]::ToBase64String($sourceModListBeforeReparse)) {
            throw 'prepare-source did not reject a nested Overwrite reparse point before moving caches or editing the stable profile.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $nestedReparsePath) { Remove-Item -LiteralPath $nestedReparsePath -Force }
        if (Test-Path -LiteralPath $nestedReparseTarget) { Remove-Item -LiteralPath $nestedReparseTarget -Recurse -Force }
    }
    $prepared = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $prepared.ok -or $prepared.state -ne 'migrated' -or @($prepared.data.movedDirectories).Count -ne 3) { throw "Stable source cache preparation failed: $($prepared | ConvertTo-Json -Depth 8 -Compress)" }
    if ($prepared.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$prepared.data.approval.oneShotReason)) { throw 'Shader-cache migration was not classified as one-shot.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $mo2 'overwrite') -Directory -Recurse -Force | Where-Object Name -Match '^(?i:ShaderCache)(?:[.]|$)').Count -ne 0) { throw 'ShaderCache directories remained in overwrite after preparation.' }
    if ((Get-Content -LiteralPath (Join-Path $source 'modlist.txt') -Raw) -notmatch ('(?m)^\+' + [regex]::Escape([string]$prepared.data.modName) + '\r?$')) { throw 'Migrated shader-cache mod was not enabled in the stable source.' }
    foreach ($move in @($prepared.data.movedDirectories)) { if (-not (Test-Path -LiteralPath ([string]$move.destinationPath) -PathType Container)) { throw "Migrated ShaderCache destination is missing: $($move.destinationPath)" } }
    $unqualifiedCreate = & $entry create -ConfigPath $unconfiguredPath -AccessId $accessId -TaskId $taskId -Label unqualified -SavePolicy MainMenuOnly -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
    if ($unqualifiedCreate.ok -or $unqualifiedCreate.errors[0] -notmatch 'valid default world-entry save') { throw 'Fresh creation did not reject an unqualified maintained source profile.' }
    $missingFixtureCreate = & $entry create -ConfigPath $missingPath -AccessId $accessId -TaskId $taskId -Label missing-fixture -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
    if ($missingFixtureCreate.ok -or $missingFixtureCreate.errors[0] -notmatch 'valid default world-entry save') { throw 'Fresh creation did not reject a missing maintained world-entry fixture.' }
    'stable-profile-drift' | Set-Content -LiteralPath (Join-Path $source 'fixture-drift.txt') -Encoding utf8
    $staleStatus = & $entry fixture-status -ConfigPath $configPath -Compact | ConvertFrom-Json
    if ($staleStatus.state -ne 'fixture-stale' -or $staleStatus.data.expectedProfileFingerprintSha256 -eq $staleStatus.data.actualProfileFingerprintSha256) { throw 'Fixture drift did not report expected and actual fingerprints.' }
    $refreshedFixture = & $entry refresh-fixture -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $refreshedFixture.ok -or -not $refreshedFixture.data.valid -or -not (Test-Path -LiteralPath $refreshedFixture.data.backupPath -PathType Leaf)) { throw 'Guarded fixture refresh did not preserve and verify the manifest.' }
    if ($refreshedFixture.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$refreshedFixture.data.approval.oneShotReason)) { throw 'Shared fixture replacement was not explicitly classified as a one-shot approval.' }
    $overwriteRoot = Join-Path $mo2 'overwrite'
    $realOverwriteRoot = Join-Path $mo2 'overwrite-reparse-target'
    Move-Item -LiteralPath $overwriteRoot -Destination $realOverwriteRoot -ErrorAction Stop
    try {
        New-Item -ItemType Junction -Path $overwriteRoot -Target $realOverwriteRoot -ErrorAction Stop | Out-Null
        $reparseCreate = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label reparse-overwrite -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false -NoExit | ConvertFrom-Json
        if ($reparseCreate.ok -or @($reparseCreate.errors | Where-Object { $_ -match 'reparse point' }).Count -ne 1 -or
            (Test-Path -LiteralPath (Join-Path $realOverwriteRoot '.codex-workspace-output-owner.json'))) {
            throw 'Workspace creation did not reject a reparse-point MO2 Overwrite root before ownership writes.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $overwriteRoot) { Remove-Item -LiteralPath $overwriteRoot -Force }
        Move-Item -LiteralPath $realOverwriteRoot -Destination $overwriteRoot -ErrorAction Stop
    }
    $iniBeforeCas = [IO.File]::ReadAllBytes($ini)
    $casRejected = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label cas-race -SavePolicy FreshGame -WorkspaceContent Modlist -InternalTestFailurePoint selected-profile-before-cas -Confirm:$false -NoExit | ConvertFrom-Json
    $iniAfterCas = [IO.File]::ReadAllBytes($ini)
    if ($casRejected.ok -or $casRejected.errors[0] -notmatch 'changed after planning and before replacement' -or [Convert]::ToBase64String($iniAfterCas) -ceq [Convert]::ToBase64String($iniBeforeCas) -or [Text.Encoding]::UTF8.GetString($iniAfterCas) -notmatch 'injected concurrent drift') { throw "Selected-profile mutation did not reject immediate preimage drift while preserving the live external bytes: $($casRejected | ConvertTo-Json -Depth 12 -Compress)" }
    [IO.File]::WriteAllBytes($ini, $iniBeforeCas)
    $conflictingSelection = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label conflicting -SavePolicy FreshGame -WorkspaceContent ModlistPlusLocalWorkMods -LocalWorkModId @('csx-aio-local-release','csx-aio-local-devbench') -Confirm:$false -NoExit | ConvertFrom-Json
    if ($conflictingSelection.ok -or $conflictingSelection.errors[0] -notmatch 'Mutually exclusive') { throw 'Workspace creation accepted mutually exclusive CSX AIO variants.' }
    $overwriteBeforeOwnerRace = Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
    $ownerRace = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label owner-race -SavePolicy FreshGame -WorkspaceContent Modlist -InternalTestFailurePoint owner-marker-before-claim -Confirm:$false -NoExit | ConvertFrom-Json
    $competingMarkerPath = Join-Path $mo2 'overwrite\.codex-workspace-output-owner.json'
    if ($ownerRace.ok -or -not (Test-Path -LiteralPath $competingMarkerPath -PathType Leaf)) { throw 'A competing Overwrite owner was not rejected by the exclusive in-lock claim.' }
    Remove-Item -LiteralPath $competingMarkerPath -Force
    if ((Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -cne $overwriteBeforeOwnerRace) { throw 'The rejected competing owner mutated MO2 Overwrite before acquiring ownership.' }
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label weather -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw "Workspace creation failed: $($created | ConvertTo-Json -Depth 12 -Compress)" }
    if ($created.data.configuration.source -ne 'explicit' -or [IO.Path]::GetFullPath([string]$created.data.configuration.path) -ne [IO.Path]::GetFullPath($configPath)) { throw 'Workspace result did not expose exact configuration resolution provenance.' }
    if ($created.data.ownerTaskId -ne $taskId -or (Get-Content -LiteralPath $ini -Raw) -notmatch ('selected_profile=@ByteArray\(' + [regex]::Escape([string]$created.data.profileName) + '\)')) { throw 'Creation did not bind and select the task-owned workspace.' }
    if ($created.data.profileName -ne $created.data.profile -or $created.data.profileDirectory -ne $created.data.profilePath -or $created.data.modListPath -ne (Join-Path $created.data.profilePath 'modlist.txt')) { throw 'Workspace profile identity fields are not explicit and canonical.' }
    if ($created.data.runtimeOutput.mode -ne 'mo2-overwrite-output' -or -not (Test-Path -LiteralPath $created.data.runtimeOutput.ownerMarkerPath -PathType Leaf)) { throw 'Workspace did not bind its exact MO2 Overwrite owner marker.' }
    if ($created.data.runtimeOutput.cachePathExistedBefore -or -not $created.data.runtimeOutput.backupPathExistedBefore) { throw 'Workspace did not record the migrated cache and pre-existing backup states.' }
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
    $transactionController = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $hiddenTransactionController = $transactionController + '.fixture-hidden'
    Move-Item -LiteralPath $transactionController -Destination $hiddenTransactionController -ErrorAction Stop
    try {
        $missingControllerIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
        if ($missingControllerIsolation.ok -or @($missingControllerIsolation.errors | Where-Object { $_ -match 'Expected exactly one shader-cache transaction controller' }).Count -ne 1) {
            throw 'A missing shader-cache transaction controller escaped the structured isolation result.'
        }
    }
    finally { Move-Item -LiteralPath $hiddenTransactionController -Destination $transactionController -ErrorAction Stop }
    $workspaceManifestPath = Join-Path (Join-Path $sessions 'workspaces') ($created.data.workspaceId + '.json')
    $workspaceManifestBytes = [IO.File]::ReadAllBytes($workspaceManifestPath)
    $missingCompletionManifest = Get-Content -LiteralPath $workspaceManifestPath -Raw | ConvertFrom-Json -Depth 40
    $missingCompletionManifest.runtimeOutput.PSObject.Properties.Remove('cacheCompletionPath')
    $missingCompletionManifest | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $workspaceManifestPath -Encoding utf8
    $missingCompletionIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if ($missingCompletionIsolation.ok -or @($missingCompletionIsolation.errors | Where-Object { $_ -match "lacks required path 'cacheCompletionPath'" }).Count -ne 1) {
        throw 'A missing runtime-output completion path escaped structured launch isolation.'
    }
    [IO.File]::WriteAllBytes($workspaceManifestPath, $workspaceManifestBytes)
    $malformedWorkspaceManifest = Get-Content -LiteralPath $workspaceManifestPath -Raw | ConvertFrom-Json -Depth 40
    $malformedWorkspaceManifest.runtimeOutput.shadowReceipt.copied = @([pscustomobject]@{ winnerClass = 'copied-provider' })
    $malformedWorkspaceManifest | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $workspaceManifestPath -Encoding utf8
    $malformedReceiptIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if ($malformedReceiptIsolation.ok -or @($malformedReceiptIsolation.errors | Where-Object { $_ -match 'malformed record' }).Count -ne 1) { throw 'A malformed backup shadow receipt was not reported as structured isolation evidence.' }
    [IO.File]::WriteAllBytes($workspaceManifestPath, $workspaceManifestBytes)
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
    if ($lateBackupIsolation.ok -or @($lateBackupIsolation.errors | Where-Object { $_ -match 'backup provider-shadow receipt no longer covers the complete current provider map' }).Count -ne 1) { throw 'MO2 backup verification did not reject provider drift.' }
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
    if ($unpreparedSession.ok -or @($unpreparedSession.errors | Where-Object { $_ -match 'shader-cache prepare plan' }).Count -ne 1) { throw "MO2 prepare did not fail closed before the bound cache plan existed: $($unpreparedSession | ConvertTo-Json -Depth 12 -Compress)" }
    $catalogEntry = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheCatalog.ps1'
    $catalogRoot = Join-Path $fixture 'shader-cache-catalog'
    $shaderSourceSha256 = [string]::new([char]'A', 64)
    function Complete-RearmedTestOutput($Workspace, [string]$OwnedAccessId) {
        $output = $Workspace.data.runtimeOutput
        $prepared = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $output.cachePath -ProfilePath $Workspace.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $output.cacheEvidenceDirectory -BuildId $output.cachePrepareArguments.BuildId -ShaderCacheAbi $output.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $Workspace.data.workspaceId -OwnershipId $Workspace.data.ownershipId -OwnerMarkerPath $output.ownerMarkerPath -OwnerMarkerSha256 $output.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
        if (-not $prepared.ok) { throw "Rearmed shader-cache preparation failed: $($prepared | ConvertTo-Json -Depth 12 -Compress)" }
        $rearmedCache = Join-Path $output.cachePath 'latest-build\generated-in-game.pso'
        $rearmedBackup = Join-Path $output.backupPath 'latest-build\generated-in-game.bin'
        New-Item -ItemType Directory -Path (Split-Path -Parent $rearmedCache), (Split-Path -Parent $rearmedBackup) -Force | Out-Null
        'rearmed-generated-cache' | Set-Content -LiteralPath $rearmedCache -Encoding utf8
        'rearmed-generated-backup' | Set-Content -LiteralPath $rearmedBackup -Encoding utf8
        $completedCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $output.cachePath -EvidenceDirectory $output.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
        $completedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $OwnedAccessId -TaskId $taskId -WorkspaceId $Workspace.data.workspaceId -Confirm:$false | ConvertFrom-Json
        if (-not $completedCache.ok -or -not $completedOutput.ok) { throw 'Rearmed workspace output did not complete.' }
    }
    $preparedCache = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $created.data.runtimeOutput.cachePath -ProfilePath $created.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $created.data.runtimeOutput.cacheEvidenceDirectory -BuildId $created.data.runtimeOutput.cachePrepareArguments.BuildId -ShaderCacheAbi $created.data.runtimeOutput.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $created.data.workspaceId -OwnershipId $created.data.ownershipId -OwnerMarkerPath $created.data.runtimeOutput.ownerMarkerPath -OwnerMarkerSha256 $created.data.runtimeOutput.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    $preparedIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if (-not $preparedCache.ok -or -not $preparedIsolation.ok -or -not $preparedIsolation.cachePlan.verification.ok -or [int]$preparedIsolation.cachePlan.verification.requiredProviderFiles -ne 2) { throw "Prepared Overwrite provider-shadow verification failed. Prepare: $($preparedCache | ConvertTo-Json -Depth 20 -Compress) Isolation: $($preparedIsolation | ConvertTo-Json -Depth 20 -Compress)" }
    $cachePlanPath = [string]$created.data.runtimeOutput.cachePlanPath
    $cachePlanBytes = [IO.File]::ReadAllBytes($cachePlanPath)
    $malformedCachePlan = Get-Content -LiteralPath $cachePlanPath -Raw | ConvertFrom-Json -Depth 40
    $malformedCachePlan.PSObject.Properties.Remove('preparedTreeSha256')
    $malformedCachePlan | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $cachePlanPath -Encoding utf8
    $malformedPlanIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($malformedPlanIsolation.ok -or @($malformedPlanIsolation.errors | Where-Object { $_ -match 'missing required state or preparation fields' }).Count -ne 1) {
        throw 'MO2 launch isolation did not reject a malformed cache-plan shape with structured evidence.'
    }
    [IO.File]::WriteAllBytes($cachePlanPath, $cachePlanBytes)
    $missingCatalogPlan = Get-Content -LiteralPath $cachePlanPath -Raw | ConvertFrom-Json -Depth 40
    $missingCatalogPlan.PSObject.Properties.Remove('catalog')
    $missingCatalogPlan | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $cachePlanPath -Encoding utf8
    $missingCatalogIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($missingCatalogIsolation.ok -or @($missingCatalogIsolation.errors | Where-Object { $_ -match 'recovery-catalog' }).Count -ne 1) {
        throw 'MO2 launch isolation accepted a cache plan without the recovery catalog required by completion.'
    }
    [IO.File]::WriteAllBytes($cachePlanPath, $cachePlanBytes)
    $buildManifestPath = [string]$created.data.runtimeOutput.communityShadersPlugin.manifestPath
    $buildManifestBytes = [IO.File]::ReadAllBytes($buildManifestPath)
    Add-Content -LiteralPath $buildManifestPath -Value ' ' -Encoding utf8
    $buildDriftIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($buildDriftIsolation.ok -or @($buildDriftIsolation.errors | Where-Object { $_ -match 'manifest, build ID, or shader-cache ABI changed' }).Count -ne 1) { throw 'MO2 launch isolation did not reject a changed build manifest.' }
    [IO.File]::WriteAllBytes($buildManifestPath, $buildManifestBytes)
    $shadowedLowerCache = Join-Path $created.data.runtimeOutput.cachePath 'Lighting\later-area.pso'
    $shadowedLowerBytes = [IO.File]::ReadAllBytes($shadowedLowerCache)
    Remove-Item -LiteralPath $shadowedLowerCache -Force
    $missingShadowIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($missingShadowIsolation.ok -or @($missingShadowIsolation.errors | Where-Object { $_ -match 'Overwrite ShaderCache lacks 1 enabled-provider path' }).Count -ne 1) { throw 'MO2 cache verification did not reject a missing provider shadow.' }
    [IO.File]::WriteAllBytes($shadowedLowerCache, $shadowedLowerBytes)
    $lowerProviderPath = Join-Path $synthesisMod 'ShaderCache\Lighting\later-area.pso'
    $lowerProviderBytes = [IO.File]::ReadAllBytes($lowerProviderPath)
    [IO.File]::WriteAllBytes($lowerProviderPath, [byte[]](9, 8, 7, 6))
    $changedProviderIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($changedProviderIsolation.ok -or @($changedProviderIsolation.errors | Where-Object { $_ -match 'copied-provider identity changed' }).Count -ne 1) { throw 'MO2 cache verification did not reject same-path provider identity drift.' }
    [IO.File]::WriteAllBytes($lowerProviderPath, $lowerProviderBytes)
    $lateLowerCache = Join-Path $synthesisMod 'ShaderCache\Lighting\second-area.pso'
    'late-lower-provider' | Set-Content -LiteralPath $lateLowerCache -Encoding utf8
    $lateLowerIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if ($lateLowerIsolation.ok -or @($lateLowerIsolation.errors | Where-Object { $_ -match 'ShaderCache provider-shadow receipt no longer covers the complete current provider map' }).Count -ne 1) { throw 'MO2 cache verification did not reject provider drift after prepare.' }
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
    $cacheCompletionPath = [string]$created.data.runtimeOutput.cacheCompletionPath
    $cacheCompletionBytes = [IO.File]::ReadAllBytes($cacheCompletionPath)
    $staleCacheCompletion = Get-Content -LiteralPath $cacheCompletionPath -Raw | ConvertFrom-Json -Depth 40
    $staleCacheCompletion.cacheBinding.workspaceId = 'stale-workspace'
    $staleCacheCompletion | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $cacheCompletionPath -Encoding utf8
    $rejectedCompletion = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit | ConvertFrom-Json
    if ($rejectedCompletion.ok -or -not (Test-Path -LiteralPath $created.data.runtimeOutput.ownerMarkerPath -PathType Leaf)) { throw 'Stale cache completion evidence did not fail closed while retaining Overwrite ownership.' }
    [IO.File]::WriteAllBytes($cacheCompletionPath, $cacheCompletionBytes)
    $taskGeneratedBackup = Join-Path $runtimeBackupRoot 'latest-build\generated-in-game.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskGeneratedBackup) -Force | Out-Null
    'generated-in-game' | Set-Content -LiteralPath $taskGeneratedBackup -Encoding utf8
    $completedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $completedOutput.ok -or $completedOutput.state -ne 'complete' -or (Test-Path -LiteralPath $created.data.runtimeOutput.ownerMarkerPath -PathType Leaf)) { throw "Workspace Overwrite output did not complete and release its owner marker: $($completedOutput | ConvertTo-Json -Depth 16 -Compress)" }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeBackupRoot 'preexisting.bin') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $runtimeBackupRoot 'hashes') -PathType Leaf)) { throw 'Backup completion did not restore the exact pre-task MO2 Overwrite tree.' }
    if (Test-Path -LiteralPath $created.data.runtimeOutput.cachePath -PathType Container) { throw 'Cache completion did not restore the migrated ShaderCache tree to an absent Overwrite state.' }
    $ordinaryCopied = Join-Path $created.data.profilePath 'saves\ordinary.ess'
    if (-not (Test-Path -LiteralPath $ordinaryCopied -PathType Leaf) -or (Get-FileHash -LiteralPath $ordinaryCopied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $source 'saves\ordinary.ess') -Algorithm SHA256).Hash) { throw 'Workspace did not copy the complete stable-source saves tree.' }
    if (-not $created.data.inheritedSaves -or $created.data.sourceSaveSnapshot.sha256 -ne $created.data.profileSaveSnapshot.sha256 -or $created.data.sourceSaveSnapshot.fileCount -ne 3) { throw 'Workspace did not report a verified inherited-save snapshot.' }
    if (-not $created.data.copiedWorldEntrySave -or -not $created.data.sourceIntegrity.integrityVerified -or $created.data.sourceIntegrity.runtimeQualified -or [string]::IsNullOrWhiteSpace([string]$created.data.sourceIntegrity.cloneVerifiedUtc) -or $null -ne $created.data.sourceIntegrity.runtimeQualificationEvidence -or $created.data.worldEntryFixture.id -ne 'interior' -or $null -ne $created.data.saveFixture) { throw 'Ordinary fresh creation did not preserve the integrity-verified world-entry baseline independently of SavePolicy.' }
    $createdModList = Get-Content -LiteralPath $created.data.modListPath -Raw
    if ($created.data.localWorkMods.workspaceContent -ne 'Modlist' -or @($created.data.localWorkMods.requestedIds).Count -ne 0 -or $createdModList -notmatch '(?m)^-\[NoDelete\] CSX AIO Local Release\r?$' -or $createdModList -notmatch '(?m)^-\[NoDelete\] CSX AIO Local DevBench\r?$') { throw 'Modlist workspace did not disable every optional CSX AIO candidate.' }
    $workspaceControlRoot = Join-Path $sessions 'workspaces'
    $interruptedCachePath = Join-Path $mo2 'overwrite\ShaderCache'
    $interruptedBackupPath = Join-Path $mo2 'overwrite\backup'
    if (Test-Path -LiteralPath $interruptedCachePath) { Remove-Item -LiteralPath $interruptedCachePath -Recurse -Force }
    Remove-Item -LiteralPath $interruptedBackupPath -Recurse -Force
    New-Item -ItemType Directory -Path $interruptedCachePath, $interruptedBackupPath -Force | Out-Null
    $interruptedOutputId = 'interrupted-output'
    $interruptedOwnershipId = 'interrupted-output-owner'
    $interruptedOutputMarker = Join-Path $mo2 'overwrite\.codex-workspace-output-owner.json'
    [pscustomobject]@{
        workspaceId = $interruptedOutputId; ownershipId = $interruptedOwnershipId
        mode = 'mo2-overwrite-output'; overwritePath = (Join-Path $mo2 'overwrite')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $interruptedOutputMarker -Encoding utf8
    $interruptedOutputMarkerHash = (Get-FileHash -LiteralPath $interruptedOutputMarker -Algorithm SHA256).Hash
    $interruptedBackupEvidence = Join-Path $workspaceControlRoot 'interrupted-output-backup'
    $transactionTool = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $interruptedSnapshot = & $transactionTool snapshot -CachePath $interruptedBackupPath -RelativeCachePath backup -EvidenceDirectory $interruptedBackupEvidence -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    if (-not $interruptedSnapshot.ok) { throw 'Could not arrange interrupted output-recovery evidence.' }
    'interrupted-generated-backup' | Set-Content -LiteralPath (Join-Path $interruptedBackupPath 'generated.bin') -Encoding utf8
    $interruptedOutputProfile = Join-Path $profiles 'Codex interrupted output fixture'
    New-Item -ItemType Directory -Path $interruptedOutputProfile -Force | Out-Null
    $interruptedOutputManifest = Join-Path $workspaceControlRoot ($interruptedOutputId + '.json')
    $interruptedOutputJournal = Join-Path $workspaceControlRoot ($interruptedOutputId + '.creation.journal.json')
    [ordered]@{
        contractVersion = '2.0.0'; operation = 'create'; phase = 'output-owner-claimed'
        workspaceId = $interruptedOutputId; ownershipId = $interruptedOwnershipId
        profilePath = $interruptedOutputProfile; manifestPath = $interruptedOutputManifest
        overwriteOwnerMarkerPath = $interruptedOutputMarker; overwriteOwnerMarkerSha256 = $interruptedOutputMarkerHash
        backupEvidenceDirectory = $interruptedBackupEvidence; cachePath = $interruptedCachePath; backupPath = $interruptedBackupPath
        cachePathExistedBefore = $false; backupPathExistedBefore = $false
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $interruptedOutputJournal -Encoding utf8
    $interruptedRecovery = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    $interruptedOutputJournalResult = Get-Content -LiteralPath $interruptedOutputJournal -Raw | ConvertFrom-Json
    if (-not $interruptedRecovery.ok -or $interruptedOutputJournalResult.phase -ne 'rolled-back' -or
        (Test-Path -LiteralPath $interruptedOutputMarker) -or (Test-Path -LiteralPath $interruptedCachePath) -or
        (Test-Path -LiteralPath $interruptedBackupPath) -or (Test-Path -LiteralPath $interruptedOutputProfile)) {
        throw 'Startup recovery did not restore absent output trees and release exact Overwrite ownership.'
    }
    foreach ($plannedMarkerPresent in @($true, $false)) {
        $plannedSuffix = if ($plannedMarkerPresent) { 'marker-created' } else { 'marker-absent' }
        $plannedWorkspaceId = 'interrupted-planned-' + $plannedSuffix
        $plannedOwnershipId = 'interrupted-planned-owner-' + $plannedSuffix
        $plannedProfile = Join-Path $profiles ('Codex ' + $plannedWorkspaceId)
        New-Item -ItemType Directory -Path $plannedProfile -Force | Out-Null
        $plannedManifest = Join-Path $workspaceControlRoot ($plannedWorkspaceId + '.json')
        $plannedJournal = Join-Path $workspaceControlRoot ($plannedWorkspaceId + '.creation.journal.json')
        $plannedMarker = Join-Path $mo2 'overwrite\.codex-workspace-output-owner.json'
        $plannedMarkerHash = [string]::new([char]'A', 64)
        if ($plannedMarkerPresent) {
            [pscustomobject]@{
                workspaceId = $plannedWorkspaceId; ownershipId = $plannedOwnershipId
                mode = 'mo2-overwrite-output'; overwritePath = (Join-Path $mo2 'overwrite')
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $plannedMarker -Encoding utf8
            $plannedMarkerHash = (Get-FileHash -LiteralPath $plannedMarker -Algorithm SHA256).Hash
        }
        [ordered]@{
            contractVersion = '2.0.0'; operation = 'create'; phase = 'output-owner-planned'
            workspaceId = $plannedWorkspaceId; ownershipId = $plannedOwnershipId
            profilePath = $plannedProfile; manifestPath = $plannedManifest
            overwriteOwnerMarkerPath = $plannedMarker; overwriteOwnerMarkerSha256 = $plannedMarkerHash
            cachePath = $interruptedCachePath; backupPath = $interruptedBackupPath
            cachePathExistedBefore = $false; backupPathExistedBefore = $false
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $plannedJournal -Encoding utf8
        $plannedRecovery = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
        $plannedJournalResult = Get-Content -LiteralPath $plannedJournal -Raw | ConvertFrom-Json
        if (-not $plannedRecovery.ok -or $plannedJournalResult.phase -ne 'rolled-back' -or
            (Test-Path -LiteralPath $plannedProfile) -or (Test-Path -LiteralPath $plannedMarker)) {
            throw "Startup recovery could not safely resolve a durable planned ownership claim ($plannedSuffix)."
        }
    }
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
    if ($verified.data.runtimeOutput.cachePathExistedBefore -or $verified.data.runtimeOutput.backupPathExistedBefore) { throw 'Workspace did not record both originally absent Overwrite trees.' }
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
    $verifiedPreparedCache = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $verified.data.runtimeOutput.cachePath -ProfilePath $verified.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $verified.data.runtimeOutput.cacheEvidenceDirectory -BuildId $verified.data.runtimeOutput.cachePrepareArguments.BuildId -ShaderCacheAbi $verified.data.runtimeOutput.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $verified.data.workspaceId -OwnershipId $verified.data.ownershipId -OwnerMarkerPath $verified.data.runtimeOutput.ownerMarkerPath -OwnerMarkerSha256 $verified.data.runtimeOutput.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    'verified-generated-cache' | Set-Content -LiteralPath (Join-Path $verified.data.runtimeOutput.cachePath 'verified-generated.pso') -Encoding utf8
    $verifiedCompletedCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $verified.data.runtimeOutput.cachePath -EvidenceDirectory $verified.data.runtimeOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
    $verifiedCompletedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $verifiedPreparedCache.ok -or -not $verifiedCompletedCache.ok -or -not $verifiedCompletedOutput.ok) { throw 'Verified fixture workspace output transactions did not complete.' }
    if ((Test-Path -LiteralPath $verified.data.runtimeOutput.cachePath) -or (Test-Path -LiteralPath $verified.data.runtimeOutput.backupPath)) { throw 'Completion did not restore both originally absent Overwrite trees to absence.' }
    foreach ($mixedCase in @(
        [pscustomobject]@{ label = 'backup-present'; cachePresent = $false; backupPresent = $true }
    )) {
        $mixedCachePath = Join-Path $mo2 'overwrite\ShaderCache'
        $mixedBackupPath = Join-Path $mo2 'overwrite\backup'
        foreach ($outputPath in @($mixedCachePath, $mixedBackupPath)) {
            if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Recurse -Force }
        }
        if ($mixedCase.cachePresent) {
            New-Item -ItemType Directory -Path $mixedCachePath -Force | Out-Null
            'mixed-cache-baseline' | Set-Content -LiteralPath (Join-Path $mixedCachePath 'baseline.bin') -Encoding utf8
        }
        if ($mixedCase.backupPresent) {
            New-Item -ItemType Directory -Path $mixedBackupPath -Force | Out-Null
            'mixed-backup-baseline' | Set-Content -LiteralPath (Join-Path $mixedBackupPath 'baseline.bin') -Encoding utf8
        }
        $mixedWorkspace = & $entry create -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -Label $mixedCase.label -SavePolicy FreshGame -WorkspaceContent Modlist -Confirm:$false | ConvertFrom-Json
        if (-not $mixedWorkspace.ok -or [bool]$mixedWorkspace.data.runtimeOutput.cachePathExistedBefore -ne [bool]$mixedCase.cachePresent -or
            [bool]$mixedWorkspace.data.runtimeOutput.backupPathExistedBefore -ne [bool]$mixedCase.backupPresent) {
            throw "Mixed Overwrite prestate was not recorded for $($mixedCase.label)."
        }
        $mixedPreparedCache = & $catalogEntry prepare -CatalogRoot $catalogRoot -CachePath $mixedWorkspace.data.runtimeOutput.cachePath -ProfilePath $mixedWorkspace.data.modListPath -ModsPath $mods -BindToOverwrite -EvidenceDirectory $mixedWorkspace.data.runtimeOutput.cacheEvidenceDirectory -BuildId $mixedWorkspace.data.runtimeOutput.cachePrepareArguments.BuildId -ShaderCacheAbi $mixedWorkspace.data.runtimeOutput.cachePrepareArguments.ShaderCacheAbi -WorkspaceId $mixedWorkspace.data.workspaceId -OwnershipId $mixedWorkspace.data.ownershipId -OwnerMarkerPath $mixedWorkspace.data.runtimeOutput.ownerMarkerPath -OwnerMarkerSha256 $mixedWorkspace.data.runtimeOutput.ownerMarkerSha256 -ShaderSourceSha256 $shaderSourceSha256 -RequireMaterializedOutput -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
        'mixed-generated-cache' | Set-Content -LiteralPath (Join-Path $mixedWorkspace.data.runtimeOutput.cachePath 'mixed-generated.pso') -Encoding utf8
        'mixed-generated-backup' | Set-Content -LiteralPath (Join-Path $mixedWorkspace.data.runtimeOutput.backupPath 'mixed-generated.bin') -Encoding utf8
        $mixedCompletedCache = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $mixedWorkspace.data.runtimeOutput.cachePath -EvidenceDirectory $mixedWorkspace.data.runtimeOutput.cacheEvidenceDirectory -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
        $mixedCompletedOutput = & $entry complete-output -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $mixedWorkspace.data.workspaceId -Confirm:$false | ConvertFrom-Json
        if (-not $mixedPreparedCache.ok -or -not $mixedCompletedCache.ok -or -not $mixedCompletedOutput.ok) { throw "Mixed Overwrite completion failed for $($mixedCase.label)." }
        if ([bool](Test-Path -LiteralPath $mixedCachePath -PathType Container) -ne [bool]$mixedCase.cachePresent -or
            [bool](Test-Path -LiteralPath $mixedBackupPath -PathType Container) -ne [bool]$mixedCase.backupPresent) {
            throw "Mixed Overwrite completion did not restore path existence for $($mixedCase.label)."
        }
        $mixedRetired = & $entry retire -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $mixedWorkspace.data.workspaceId -Confirm:$false | ConvertFrom-Json
        if (-not $mixedRetired.ok -or (Test-Path -LiteralPath $mixedWorkspace.data.profilePath)) { throw "Mixed-case workspace retirement failed for $($mixedCase.label)." }
    }
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
    $nextAccess = Invoke-MO2RequestAccess -Config $config -Label fixture-resume -RuntimeRoute SteamVRNull; $nextAccessId = [string]$nextAccess.data.access.accessId
    $wrongOwner = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId 'different-task' -WorkspaceId $created.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
    if ($wrongOwner.ok -or $wrongOwner.errors[0] -notmatch 'different task') { throw 'A different task identity was allowed to resume the retained workspace.' }
    $overwriteBeforeInterruptedResume = Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
    & $powerShell -NoProfile -NonInteractive -File $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -InternalTestFailurePoint resume-interrupt-after-output-rearm -Confirm:$false -NoExit | Out-Null
    if ($LASTEXITCODE -ne 91) { throw 'Interrupted resume fixture did not terminate after publishing recoverable output-rearm evidence.' }
    $null = & $entry list-task -ConfigPath $configPath -TaskId $taskId -Compact | ConvertFrom-Json
    $interruptedResumeJournal = Get-ChildItem -LiteralPath $workspaceControlRoot -Filter ($created.data.workspaceId + '.resume.*.journal.json') -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $interruptedResumeData = Get-Content -LiteralPath $interruptedResumeJournal.FullName -Raw | ConvertFrom-Json
    $postRecoveryManifest = Get-Content -LiteralPath (Join-Path $workspaceControlRoot ($created.data.workspaceId + '.json')) -Raw | ConvertFrom-Json
    if ($interruptedResumeData.phase -ne 'rolled-back' -or
        [string]$postRecoveryManifest.accessId -ne [string]$accessId -or
        (Test-Path -LiteralPath (Join-Path $mo2 'overwrite\.codex-workspace-output-owner.json')) -or
        (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -cne $overwriteBeforeInterruptedResume) {
        throw 'Startup recovery did not roll back the interrupted runtime-output rearm, exact manifest, and Overwrite tree.'
    }
    $resumed = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $resumed.ok -or $resumed.state -ne 'workspace-resumed' -or $resumed.data.accessId -ne $nextAccessId -or -not (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'task-state.txt'))) { throw "Retained workspace was not rebound without losing task state: $($resumed | ConvertTo-Json -Depth 12 -Compress)" }
    if ([string]$resumed.data.runtimeOutput.cacheEvidenceDirectory -ceq [string]$created.data.runtimeOutput.cacheEvidenceDirectory -or
        @($resumed.data.runtimeOutputHistory).Count -ne 1 -or
        (Test-Path -LiteralPath ([string]$resumed.data.runtimeOutput.cacheCompletionPath))) {
        throw 'Retained workspace resume did not create a fresh output transaction while preserving the completed transaction history.'
    }
    Complete-RearmedTestOutput -Workspace $resumed -OwnedAccessId $nextAccessId
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch ('selected_profile=@ByteArray\(' + [regex]::Escape([string]$created.data.profileName) + '\)')) { throw 'Resume did not select the retained task profile.' }
    $selectedText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($ini))
    $selectedWithBom = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.UTF8Encoding]::new($false).GetBytes($selectedText)
    [IO.File]::WriteAllBytes($ini, $selectedWithBom)
    $alreadySelectedBefore = [IO.File]::ReadAllBytes($ini)
    $alreadySelectedResume = & $entry resume -ConfigPath $configPath -AccessId $nextAccessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false | ConvertFrom-Json
    $alreadySelectedAfter = [IO.File]::ReadAllBytes($ini)
    if (-not $alreadySelectedResume.ok -or [Convert]::ToBase64String($alreadySelectedAfter) -cne [Convert]::ToBase64String($alreadySelectedBefore)) { throw 'Resuming an already-selected profile did not preserve exact MO2 INI bytes.' }
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
    if (-not $resumedVerified.ok) { throw "Second retained workspace could not be explicitly resumed: $($resumedVerified | ConvertTo-Json -Depth 12 -Compress)" }
    Complete-RearmedTestOutput -Workspace $resumedVerified -OwnedAccessId $nextAccessId
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
    [pscustomobject]@{ok=$true; assertions=100; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally {
    $env:CSX_MO2_PROFILE_CONTROL_ROOT = $priorProfileControlRoot
    $env:CSX_SHADER_CACHE_CONTROL_ROOT = $priorShaderCacheControlRoot
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
