# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2ProfileControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-profile-control-' + [guid]::NewGuid().ToString('N'))
$priorControlRoot = $env:CSX_MO2_PROFILE_CONTROL_ROOT
$env:CSX_MO2_PROFILE_CONTROL_ROOT = Join-Path $fixture 'target-controls'
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $profile = Join-Path $fixture 'modlist.txt'
    $evidence = Join-Path $fixture 'evidence'
    $original = [Text.Encoding]::UTF8.GetBytes("#fixture`r`n+Exact Test Mod`r`n-Enable Test Mod`r`n-Other Mod`r`n")
    [IO.File]::WriteAllBytes($profile, $original)
    $originalHash = (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash
    $fixtureProcessNames = @('MO2ProfileControlImpossibleFixtureProcess')
    $mods = Join-Path $fixture 'mods'
    $newMod = Join-Path $mods 'New Test Mod'
    $exactMod = Join-Path $mods 'Exact Test Mod'
    $enableMod = Join-Path $mods 'Enable Test Mod'
    foreach ($mod in @($newMod, $exactMod, $enableMod)) {
        New-Item -ItemType Directory -Path (Join-Path $mod 'SKSE\Plugins') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $mod 'SKSE\Plugins\Example.dll'), $mod)
    }

    $registerEvidence = Join-Path $fixture 'register-evidence'
    $registered = & $script register -ProfilePath $profile -ModName 'New Test Mod' -ModDirectory $newMod -Placement After -RelativeToMod 'Exact Test Mod' -EvidenceDirectory $registerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($registered.enabled -or $registered.marker -ne '-') { throw 'Register did not create one disabled marker.' }
    $registeredLines = Get-Content -LiteralPath $profile
    if ($registeredLines[2] -ne '-New Test Mod') { throw 'Register did not honor exact relative placement.' }
    $registerRestored = & $script restore -ProfilePath $profile -ModName 'New Test Mod' -EvidenceDirectory $registerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($null -ne $registerRestored.marker -or (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Register restore did not remove the owned marker byte-identically.' }

    $winnerRegisterEvidence = Join-Path $fixture 'register-winner-evidence'
    $winningPathsFile = Join-Path $fixture 'winning-paths.json'
    '["SKSE\\Plugins\\Example.dll"]' | Set-Content -LiteralPath $winningPathsFile -Encoding utf8
    $registeredWinner = & $script register-winning -ProfilePath $profile -ModName 'New Test Mod' -ModDirectory $newMod -ModsDirectory $mods -WinningPathsFile $winningPathsFile -EvidenceDirectory $winnerRegisterEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    $winnerLines = Get-Content -LiteralPath $profile
    if (-not $registeredWinner.enabled -or $winnerLines[1] -ne '+New Test Mod') { throw 'Register-winning did not enable and place the target before the earliest enabled provider.' }
    $winnerReceipt = Get-Content -LiteralPath (Join-Path $winnerRegisterEvidence 'modlist-control.receipt.json') -Raw | ConvertFrom-Json
    if (-not $winnerReceipt.winnerProof.verified -or @($winnerReceipt.winnerProof.displacedProviders).Count -ne 1) { throw 'Register-winning did not record its provider proof.' }
    $winnerRegisterRestored = & $script restore -ProfilePath $profile -ModName 'New Test Mod' -EvidenceDirectory $winnerRegisterEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($null -ne $winnerRegisterRestored.marker -or $winnerRegisterRestored.sha256 -ne $originalHash) { throw 'Register-winning restore was not byte-identical.' }

    $ensureWinnerEvidence = Join-Path $fixture 'ensure-winner-evidence'
    $ensuredWinner = & $script ensure-winner -ProfilePath $profile -ModName 'Enable Test Mod' -ModDirectory $enableMod -ModsDirectory $mods -WinningPaths 'SKSE\Plugins\Example.dll' -EvidenceDirectory $ensureWinnerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    $ensuredLines = Get-Content -LiteralPath $profile
    if (-not $ensuredWinner.enabled -or $ensuredLines[1] -ne '+Enable Test Mod') { throw 'Ensure-winner did not enable and move the existing target before providers.' }
    $ensureWinnerRestored = & $script restore -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $ensureWinnerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($ensureWinnerRestored.enabled -or $ensureWinnerRestored.sha256 -ne $originalHash) { throw 'Ensure-winner restore was not byte-identical.' }

    $inspect = & $script inspect -ProfilePath $profile -ModName 'Exact Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $inspect.enabled) { throw 'Inspect did not report the enabled marker.' }
    $compactInspectText = & $script inspect -ProfilePath $profile -ModName 'Exact Test Mod' -BlockingProcessNames $fixtureProcessNames -Compact
    if ($compactInspectText -match "`r|`n" -or -not ($compactInspectText | ConvertFrom-Json).enabled) { throw 'Compact inspect did not emit one valid JSON line.' }
    if (-not $inspect.approval.reusableApprovalEligible -or @($inspect.approval.reusablePrefix).Count -ne 6 -or $inspect.approval.reusablePrefix[4] -ne [IO.Path]::GetFullPath($script) -or $inspect.approval.reusablePrefix[5] -ne 'inspect') { throw 'Inspect did not expose its exact reusable approval prefix.' }
    $directoryInspect = & $script inspect -ProfilePath $fixture -ModName 'Exact Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $directoryInspect.enabled -or $directoryInspect.modListPath -ne $profile) { throw 'Profile directory input did not normalize to its exact modlist.' }
    if ($directoryInspect.profileDirectory -ne $fixture -or $directoryInspect.profileName -ne [IO.Path]::GetFileName($fixture)) { throw 'Profile identity fields are not explicit and canonical.' }
    $enableInspect = & $script inspect -ProfilePath $profile -ModName 'Enable Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($enableInspect.enabled) { throw 'Inspect did not report the disabled marker.' }

    $profileControlDirectory = @(Get-ChildItem -LiteralPath $env:CSX_MO2_PROFILE_CONTROL_ROOT -Directory)[0].FullName
    $heldLock = [IO.File]::Open((Join-Path $profileControlDirectory 'target.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $contentionRejected = $false
    try {
        try { $null = & $script disable -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory (Join-Path $fixture 'contention-evidence') -BlockingProcessNames $fixtureProcessNames -TransactionLockTimeoutMilliseconds 150 -Confirm:$false }
        catch { $contentionRejected = $_.Exception.Message -like 'Timed out waiting for the profile transaction lock:*' }
    }
    finally { $heldLock.Dispose() }
    if (-not $contentionRejected -or (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Contended profile mutation did not fail boundedly without changing the live preimage.' }

    $disabled = & $script disable -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($disabled.enabled -or $disabled.sha256 -eq $originalHash) { throw 'Disable did not change exactly the marker state.' }
    if ($disabled.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$disabled.approval.oneShotReason)) { throw 'Profile mutation was not explicitly classified as a one-shot approval.' }
    $disableReceipt = Get-Content -LiteralPath (Join-Path $evidence 'modlist-control.receipt.json') -Raw | ConvertFrom-Json
    $disableJournal = Get-Content -LiteralPath ([string]$disableReceipt.transactionJournalPath) -Raw | ConvertFrom-Json
    if ($disableReceipt.contractVersion -ne '2.0.0' -or $disableJournal.phase -ne 'committed' -or $disableJournal.transactionId -ne $disableReceipt.transactionId) { throw 'Profile mutation did not retain a committed write-ahead transaction journal.' }

    $restored = & $script restore -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $restored.enabled -or $restored.sha256 -ne $originalHash) { throw 'Restore did not reproduce the original hash.' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($profile))) { throw 'Restore was not byte-identical.' }

    $whatIfEvidence = Join-Path $fixture 'whatif-evidence'
    $null = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $whatIfEvidence -BlockingProcessNames $fixtureProcessNames -WhatIf
    if ((Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Enable WhatIf changed the profile.' }
    if (Test-Path -LiteralPath $whatIfEvidence) { throw 'Enable WhatIf created evidence files.' }

    $enableEvidence = Join-Path $fixture 'enable-evidence'
    $enabled = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $enableEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $enabled.enabled -or $enabled.sha256 -eq $originalHash) { throw 'Enable did not change exactly the marker state.' }
    $receipt = Get-Content -LiteralPath (Join-Path $enableEvidence 'modlist-control.receipt.json') -Raw | ConvertFrom-Json
    if ($receipt.operation -ne 'enable') { throw 'Enable receipt did not record its operation.' }

    $enableRestored = & $script restore -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $enableEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($enableRestored.enabled -or $enableRestored.sha256 -ne $originalHash) { throw 'Enable restore did not reproduce the original marker state.' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($profile))) { throw 'Enable restore was not byte-identical.' }

    $recoveryEvidence = Join-Path $fixture 'restart-recovery-evidence'
    $recoveryEnabled = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $recoveryEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    $recoveryReceiptPath = Join-Path $recoveryEvidence 'modlist-control.receipt.json'
    $recoveryReceipt = Get-Content -LiteralPath $recoveryReceiptPath -Raw | ConvertFrom-Json
    $recoveryJournalPath = [string]$recoveryReceipt.transactionJournalPath
    $recoveryJournal = Get-Content -LiteralPath $recoveryJournalPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $recoveryReceiptPath -Force
    $recoveryJournal.phase = 'writing-live'; $recoveryJournal.committedUtc = $null
    $recoveryJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recoveryJournalPath -Encoding utf8
    $recoveryJournal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ([string]$recoveryJournal.evidenceJournalPath) -Encoding utf8
    $recoveryTriggered = $false
    try { $null = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -BlockingProcessNames $fixtureProcessNames -Confirm:$false }
    catch { $recoveryTriggered = $_.Exception.Message -match 'EvidenceDirectory' }
    $recoveredAuthority = Get-Content -LiteralPath $recoveryJournalPath -Raw | ConvertFrom-Json
    if (-not $recoveryTriggered -or $recoveredAuthority.phase -ne 'recovered-preimage' -or (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Restart recovery did not restore the exact profile preimage before validating the next request.' }

    $rollbackEvidence = Join-Path $fixture 'rollback-evidence'
    New-Item -ItemType Directory -Path (Join-Path $rollbackEvidence 'modlist-control.receipt.json') -Force | Out-Null
    $rollbackObserved = $false
    try { $null = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $rollbackEvidence -BlockingProcessNames $fixtureProcessNames -Confirm:$false }
    catch { $rollbackObserved = $_.Exception.Message -like 'Profile transaction failed; exact preimage restored.*' }
    $rollbackJournalPath = @(Get-ChildItem -LiteralPath $rollbackEvidence -Filter 'modlist-control.*.journal.json' -File)[0].FullName
    $rollbackJournal = Get-Content -LiteralPath $rollbackJournalPath -Raw | ConvertFrom-Json
    if (-not $rollbackObserved -or $rollbackJournal.phase -ne 'rolled-back' -or (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Post-write receipt failure did not roll back and journal the exact live preimage.' }

    [pscustomobject]@{ ok = $true; assertions = 30; restoredSha256 = $enableRestored.sha256 } | ConvertTo-Json
}
finally {
    $env:CSX_MO2_PROFILE_CONTROL_ROOT = $priorControlRoot
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
