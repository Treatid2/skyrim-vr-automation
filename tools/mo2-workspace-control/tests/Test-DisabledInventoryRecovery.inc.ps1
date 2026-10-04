# SPDX-License-Identifier: GPL-3.0-or-later
# Production entry-point regression for MO2's disabled-only append on open.
function Invoke-DisabledCase([string]$Operation, [hashtable]$Extra = @{}) {
    $arguments = @{ ConfigPath = $configPath; AccessId = $accessId; TaskId = $taskId; WorkspaceId = $createdBaseline.data.workspaceId; ExpectedCurrentSha256 = (Get-FileHash -LiteralPath $createdBaseline.data.modListPath).Hash; NoExit = $true; Confirm = $false; Compact = $true }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return & $entry $Operation @arguments | ConvertFrom-Json -Depth 40
}
$profile = $createdBaseline.data.modListPath
$pinnedBytes = [IO.File]::ReadAllBytes($profile)
$pinnedHash = (Get-FileHash -LiteralPath $profile).Hash
Assert-Preserved (([IO.File]::ReadAllText($profile)).Contains('-Installed unlisted fixture')) 'Creation did not normalize clone before pinning.'
Assert-Preserved (-not ([IO.File]::ReadAllText($sourceModListPath)).Contains('Installed unlisted fixture')) 'Creation normalized the maintained source.'
$liveConfig = Join-Path $mo2 'overwrite\SKSE\Plugins\CommunityShaders'
[void][IO.Directory]::CreateDirectory($liveConfig)
foreach ($name in @('SettingsDefault.json','SettingsUser.json')) { [IO.File]::WriteAllText((Join-Path $liveConfig $name), '{}') }
$staged = & $entry stage-config -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $createdBaseline.data.workspaceId -UnmanagedConfigPath (Join-Path $fixture 'game\Data\SKSE\Plugins\CommunityShaders') -ConfigScopeNote 'Isolated fixture; no archives/unmanaged config.' -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved $staged.ok 'Fixture config stage failed.'
$bound = & $entry bind-config -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $createdBaseline.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved $bound.ok 'Fixture config bind failed.'
foreach ($name in @('Late installed one','Late installed two')) { [void][IO.Directory]::CreateDirectory((Join-Path $mods $name)) }
[IO.File]::AppendAllText($profile, "-Late installed one`r`n-Late installed two`r`n", [Text.UTF8Encoding]::new($false))
$driftHash = (Get-FileHash -LiteralPath $profile).Hash
$configHeld = Invoke-DisabledCase recover-disabled-append
Assert-Preserved (-not $configHeld.ok -and ($configHeld.errors -join ';') -match 'Complete configuration custody' -and (Get-FileHash -LiteralPath $profile).Hash -ceq $driftHash) 'Recovery bypassed active config custody.'
$configCompleted = & $entry complete-config -ConfigPath $configPath -AccessId $accessId -TaskId $taskId -WorkspaceId $createdBaseline.data.workspaceId -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved $configCompleted.ok 'Independent config completion was blocked by disabled drift.'
$blocked = & $catalogEntry complete -CatalogRoot $catalogRoot -CachePath $output.cachePath -EvidenceDirectory $output.cacheEvidenceDirectory -WorkingSetStatus unverified -BlockingProcessNames MO2WorkspaceImpossibleFixtureProcess -NoExit -Confirm:$false | ConvertFrom-Json
Assert-Preserved (-not $blocked.ok) 'Drift no longer reproduces strict catalog completion block.'
$manifestPath = Join-Path (Join-Path $sessions 'workspaces') ($createdBaseline.data.workspaceId + '.json')
$ws = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 80
$immutablePaths = @($manifestPath, $output.cachePlanPath, $output.backupPlanPath, $ws.configCustody.planPath, $output.ownerMarkerPath)
$immutableHashes = @($immutablePaths | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
$wrongCas = Invoke-DisabledCase recover-disabled-append @{ExpectedCurrentSha256=[string]::new([char]'0',64)}
Assert-Preserved (-not $wrongCas.ok -and ($wrongCas.errors -join ';') -match 'CAS') 'Recovery accepted wrong current SHA.'
$wrongTask = Invoke-DisabledCase recover-disabled-append @{TaskId='foreign'}
Assert-Preserved (-not $wrongTask.ok) 'Recovery accepted foreign task.'
$wrongLease = Invoke-DisabledCase recover-disabled-append @{AccessId='foreign'}
Assert-Preserved (-not $wrongLease.ok) 'Recovery accepted foreign access.'
$open = Invoke-DisabledCase recover-disabled-append @{ConfigPath=$openConfigPath}
Assert-Preserved (-not $open.ok -and ($open.errors -join ';') -match 'closed-state') 'Recovery accepted open app state.'
$activeNormalize = Invoke-DisabledCase normalize-installed
Assert-Preserved (-not $activeNormalize.ok) 'Normalization rewrote active pinned bindings.'
$preview = Invoke-DisabledCase recover-disabled-append @{WhatIf=$true}
Assert-Preserved ($preview.ok -and $preview.state -eq 'dry-run' -and (Get-FileHash -LiteralPath $profile).Hash -ceq $driftHash -and -not (Test-Path -LiteralPath $preview.data.profile.receiptPath)) 'Recovery preview changed bytes or wrote evidence.'
$recovered = Invoke-DisabledCase recover-disabled-append
Assert-Preserved ($recovered.ok -and $recovered.state -eq 'pinned-profile-restored-completion-required' -and (Get-FileHash -LiteralPath $profile).Hash -ceq $pinnedHash) "Exact suffix recovery failed: $($recovered | ConvertTo-Json -Depth 12 -Compress)"
Assert-Preserved ((Get-FileHash -LiteralPath $recovered.data.profile.backupPath).Hash -ceq $driftHash -and (Test-Path -LiteralPath $recovered.data.profile.receiptPath)) 'Recovery did not retain exact drift bytes/receipt.'
for ($i=0; $i -lt $immutablePaths.Count; $i++) { Assert-Preserved ((Get-FileHash -LiteralPath $immutablePaths[$i]).Hash -ceq $immutableHashes[$i]) 'Recovery changed immutable plan/manifest/owner bytes.' }
$retry = Invoke-DisabledCase recover-disabled-append
Assert-Preserved ($retry.ok -and -not $retry.data.profile.operationResult.changed) 'Already recovered profile was not a mutation-free no-op.'
