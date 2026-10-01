# SPDX-License-Identifier: GPL-3.0-or-later
# Loaded only in the isolated prepared requalification fixture.
$activeManifestPath = Join-Path $sessions ('workspaces\' + $created.data.workspaceId + '.json')
$activeMarkerBytes = [IO.File]::ReadAllBytes($oldOutput.ownerMarkerPath)
$activeOutputJson = $oldOutput | ConvertTo-Json -Depth 80 -Compress
$activeTreeHash = Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')
$activePlanHashes = @($oldOutput.cachePlanPath, $oldOutput.backupPlanPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ','
function Assert-ActiveResumeGeneration($Result) {
    if (-not $Result.ok -or $Result.data.lastResumeDisposition -cne 'rebind-active-output' -or
        ($Result.data.runtimeOutput | ConvertTo-Json -Depth 80 -Compress) -cne $activeOutputJson -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($oldOutput.ownerMarkerPath)) -cne [Convert]::ToBase64String($activeMarkerBytes) -or
        (@($oldOutput.cachePlanPath, $oldOutput.backupPlanPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ',') -cne $activePlanHashes -or
        (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')) -cne $activeTreeHash -or
        $Result.data.PSObject.Properties['runtimeOutputHistory']) { throw 'Active resume changed the output generation, marker, physical trees, plans or supersession history.' }
}
foreach ($seam in @('', 'resume-interrupt-after-active-output-rebind', 'resume-interrupt-after-manifest-write')) {
    $released = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    $nextAccess = Invoke-MO2RequestAccess -Config $config -TaskId $taskId -Label active-resume-fixture -RuntimeRoute SteamVRNull
    if (-not $released.ok -or -not $nextAccess.ok) { throw 'Active-resume replacement lease failed.' }
    $accessId = [string]$nextAccess.data.access.accessId
    if ($seam) {
        $preimageBytes = [IO.File]::ReadAllBytes($activeManifestPath)
        $raw = & $powerShell -NoProfile -NonInteractive -File $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -InternalTestFailurePoint $seam -Confirm:$false -Compact
        $expectedExit = if ($seam -eq 'resume-interrupt-after-active-output-rebind') { 96 } else { 97 }
        if ($LASTEXITCODE -ne $expectedExit) { throw "Active resume did not reach $seam`: $raw" }
        $pendingRebind = @(Get-ChildItem -LiteralPath (Split-Path $activeManifestPath) -Filter '*.resume.*.journal.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 80 } | Where-Object phase -notin @('committed','rolled-back'))
        if ($pendingRebind.Count -ne 1 -or $null -eq $pendingRebind[0].runtimeOutputRebind -or $null -ne $pendingRebind[0].runtimeOutputRearm) { throw 'Active interruption lost its exact rebind-only journal.' }
        $pendingState = @((Get-FileHash -LiteralPath $activeManifestPath).Hash, (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite')))
        $foreignRecovery = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId different-task -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
        if ($foreignRecovery.ok -or (@((Get-FileHash -LiteralPath $activeManifestPath).Hash, (Get-TestProfileFingerprint (Join-Path $mo2 'overwrite'))) -join ',') -cne ($pendingState -join ',')) { throw 'Foreign task recovered an interrupted active rebind.' }
        $recovery = & $entry inspect -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -NoExit -Compact | ConvertFrom-Json
        if ($recovery.ok -or ($recovery.errors -join ' ') -notmatch 'different MO2 access lease' -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($activeManifestPath)) -cne [Convert]::ToBase64String($preimageBytes)) { throw 'Interrupted active resume did not recover the exact original manifest before rebinding.' }
    }
    $resumedActive = & $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
    Assert-ActiveResumeGeneration $resumedActive
    $created.data = $resumedActive.data
}
$validManifestBytes = [IO.File]::ReadAllBytes($activeManifestPath)
foreach ($field in @('ownerTaskId','workspaceId','ownershipId','overwritePath')) {
    $foreignMarker = [Text.Encoding]::UTF8.GetString($activeMarkerBytes) | ConvertFrom-Json -Depth 30
    $foreignMarker.$field = if ($field -eq 'overwritePath') { Join-Path $fixture 'wrong-overwrite' } else { 'foreign-' + $field }
    [IO.File]::WriteAllText($oldOutput.ownerMarkerPath, ($foreignMarker | ConvertTo-Json -Depth 30))
    # Even a coherently updated digest cannot authorize another owner/mapping.
    $foreignManifest = [Text.Encoding]::UTF8.GetString($validManifestBytes) | ConvertFrom-Json -Depth 80
    $foreignManifest.runtimeOutput.ownerMarkerSha256 = (Get-FileHash -LiteralPath $oldOutput.ownerMarkerPath).Hash
    [IO.File]::WriteAllText($activeManifestPath, ($foreignManifest | ConvertTo-Json -Depth 80))
    $beforeForeign = @($activeManifestPath,$oldOutput.ownerMarkerPath,$config.mo2.ini,$created.data.modListPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ','
    $foreignResume = & $entry resume -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $created.data.workspaceId -Confirm:$false -NoExit -Compact | ConvertFrom-Json
    $afterForeign = @($activeManifestPath,$oldOutput.ownerMarkerPath,$config.mo2.ini,$created.data.modListPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ','
    if ($foreignResume.ok -or $beforeForeign -cne $afterForeign) { throw "Active resume admitted or mutated foreign $field." }
    [IO.File]::WriteAllBytes($activeManifestPath, $validManifestBytes)
    [IO.File]::WriteAllBytes($oldOutput.ownerMarkerPath, $activeMarkerBytes)
}
'PASS: exact active generation survives three replacement leases, pre/post-manifest interruption recovery, and coherent foreign task/workspace/ownership/path refusal.'
