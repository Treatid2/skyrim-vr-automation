# SPDX-License-Identifier: GPL-3.0-or-later
# Runs after real fixture workspace creation and cache preparation. No mocks in
# prepare, binding, cache inspection, or copied-controller launch preview.
$bundleChecks = [Collections.Generic.List[string]]::new()
function Assert-Bundle([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "Durable bundle regression: $Name" }
    $bundleChecks.Add($Name)
}
$toolRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixtureSource = Join-Path $fixture 'isolated-producer'
$files = @('mo2-control/Invoke-MO2Control.ps1','mo2-control/ConfigResolution.psm1',
    'mo2-control/MO2Control.psm1','mo2-control/CSXConfigCustodyProof.ps1',
    'shader-cache-control/Invoke-CSXShaderCacheTransaction.ps1',
    'shader-cache-control/ShaderCacheInventory.ps1','shader-cache-control/ShaderCacheTargetLock.psm1')
foreach ($relative in $files) {
    $destination = Join-Path $fixtureSource $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolRoot $relative) -Destination $destination
}
$producer = Join-Path $fixtureSource 'mo2-control/Invoke-MO2Control.ps1'
$preparedBundle = & $producer prepare -ConfigPath $configPath -AccessId $accessId -Profile $created.data.profileName -Executable Test -Label copied-cache-inspection -Compact -NoExit | ConvertFrom-Json -Depth 70
Assert-Bundle ($preparedBundle.ok -and $preparedBundle.state -eq 'prepared') 'public prepare commits real fixture output/session admission'
$sessionId = [string]$preparedBundle.data.session.sessionId
$controllerPath = [string]$preparedBundle.data.controllerPath
$controllerDirectory = Split-Path -Parent $controllerPath
$boundLock = Get-Content -LiteralPath $lock -Raw | ConvertFrom-Json -Depth 70
$boundManifest = Get-Content -LiteralPath (Join-Path $preparedBundle.data.sessionPath 'session.json') -Raw | ConvertFrom-Json -Depth 70
$binding = $boundLock.controllerBundleBinding
Assert-Bundle ($binding.inventoryVersion -ceq '1.1.0' -and $binding.bundleContractVersion -ceq '1.1.0' -and @($binding.files).Count -eq 8) 'new version binds all eight producer members'
Assert-Bundle (($binding | ConvertTo-Json -Depth 70 -Compress) -ceq ($boundManifest.controllerBundleBinding | ConvertTo-Json -Depth 70 -Compress)) 'authoritative lease and manifest project identical dependency closure'
foreach ($member in $binding.files) {
    Assert-Bundle ((Get-FileHash -LiteralPath $member.path).Hash -ceq $member.sha256 -and (Get-Item -LiteralPath $member.path).Length -eq $member.bytes -and -not [string]::IsNullOrWhiteSpace($member.physicalIdentity)) "bound bytes/hash/physical identity: $($member.name)"
}
# Remove the exact producer from its original location without deleting it;
# a fresh child cannot import previously cached source modules or find fallback.
Remove-Module MO2Control,ConfigResolution,ShaderCacheTargetLock -Force -ErrorAction SilentlyContinue
Move-Item -LiteralPath $fixtureSource -Destination ($fixtureSource + '.retained')
Assert-Bundle (-not (Test-Path -LiteralPath $producer)) 'producer checkout unavailable before child launch preview'
function Invoke-CopiedBundlePreview {
    $start = [Diagnostics.ProcessStartInfo]::new($powerShell)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.WorkingDirectory = $fixture
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$controllerPath,'launch','-SessionId',$sessionId,'-WhatIf','-Compact')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'Copied-controller preview exceeded 30 seconds.' }
    $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode; $process.Dispose()
    $parsed = $stdout | ConvertFrom-Json -Depth 70
    return [pscustomobject]@{ exitCode = $exitCode; result = $parsed; stderr = $stderr }
}
$lockHash = (Get-FileHash -LiteralPath $lock).Hash
$manifestHash = (Get-FileHash -LiteralPath (Join-Path $preparedBundle.data.sessionPath 'session.json')).Hash
$good = Invoke-CopiedBundlePreview
Assert-Bundle ($good.exitCode -eq 0 -and $good.result.ok -and $good.result.state -eq 'dry-run') 'fresh copied-controller public launch preview passes independently'
Assert-Bundle ($preparedBundle.data.session.runtimeOutputIsolation.communityShadersBuildInspection -ceq 'matched' -and $preparedBundle.data.session.runtimeOutputIsolation.cachePlan.verification.ok -and $preparedBundle.data.session.runtimeOutputIsolation.backupVerification.ok) 'real preparation verifies DLL identity and both output shadows; independent launch preview passed'
Assert-Bundle ((Get-FileHash -LiteralPath $lock).Hash -ceq $lockHash -and (Get-FileHash -LiteralPath (Join-Path $preparedBundle.data.sessionPath 'session.json')).Hash -ceq $manifestHash -and -not (Test-Path -LiteralPath (Join-Path $preparedBundle.data.sessionPath 'mo2-launch-started.json'))) 'preview leaves lease/session bytes unchanged and never dispatches MO2/game'
$modulePath = Join-Path $controllerDirectory 'shader-cache-control/ShaderCacheTargetLock.psm1'
$moduleHash = (Get-FileHash -LiteralPath $modulePath).Hash
Move-Item -LiteralPath $modulePath -Destination ($modulePath + '.retained')
try {
    $missing = Invoke-CopiedBundlePreview
    Assert-Bundle ($missing.exitCode -ne 0 -and -not $missing.result.ok -and ($missing.result.errors -join ';') -match 'Could not inspect bound MO2 Overwrite output' -and ($missing.result.errors -join ';') -notmatch 'ABI changed') 'missing dependency vetoes preview without fabricating artifact drift'
    Assert-Bundle ($missing.result.data.runtimeOutputIsolation.communityShadersBuildInspection -ceq 'unavailable') 'failed inspection explicitly remains unavailable'
} finally { Move-Item -LiteralPath ($modulePath + '.retained') -Destination $modulePath }
Assert-Bundle ((Get-FileHash -LiteralPath $modulePath).Hash -ceq $moduleHash) 'synthetic dependency refusal retains exact original module bytes'
# Actual readable build drift must still veto admission, independently of the
# missing-module case. Restore only this synthetic manifest's original bytes.
$buildManifestPath = Join-Path $loaderMod 'SKSE/Plugins/CSX.BuildManifest.json'
$originalBuildManifest = [IO.File]::ReadAllBytes($buildManifestPath)
try {
    $changedBuild = [Text.Encoding]::UTF8.GetString($originalBuildManifest) | ConvertFrom-Json
    $changedBuild.buildId = 'genuinely-changed-fixture-build'
    $changedBuild | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $buildManifestPath -Encoding utf8NoBOM
    $drift = Invoke-CopiedBundlePreview
    Assert-Bundle (-not $drift.result.ok -and ($drift.result.errors -join ';') -match 'ABI changed' -and $drift.result.data.runtimeOutputIsolation.communityShadersBuildInspection -ceq 'mismatch') 'successfully inspected build drift remains a distinct refusal'
} finally { [IO.File]::WriteAllBytes($buildManifestPath, $originalBuildManifest) }
Import-Module (Join-Path $controllerDirectory 'MO2Control.psm1') -Force
$copiedModule = Get-Module MO2Control
$bindingPassed = & $copiedModule { param($l,$m) Assert-MO2ControllerBundleBinding -Data $l -Manifest $m } $boundLock $boundManifest
Assert-Bundle ($bindingPassed.inventoryVersion -ceq '1.1.0') 'complete new inventory accepted by independent binding verifier'
$badLock = $boundLock | ConvertTo-Json -Depth 70 | ConvertFrom-Json -Depth 70
$badManifest = $boundManifest | ConvertTo-Json -Depth 70 | ConvertFrom-Json -Depth 70
# Test omission even if a fabricated receipt and both projections agree.
$badReceipt = Get-Content -LiteralPath $binding.receiptPath -Raw | ConvertFrom-Json -Depth 70
$badReceipt.files = @($badReceipt.files | Where-Object { $_.name -notlike '*ShaderCacheTargetLock.psm1' })
$originalReceipt = [IO.File]::ReadAllBytes($binding.receiptPath)
try {
    $badReceipt | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath $binding.receiptPath -Encoding utf8NoBOM
    $badLock.controllerBundleBinding.files = @($badLock.controllerBundleBinding.files | Where-Object { $_.name -notlike '*ShaderCacheTargetLock.psm1' })
    $badLock.controllerBundleBinding.receiptBytes = (Get-Item -LiteralPath $binding.receiptPath).Length
    $badLock.controllerBundleBinding.receiptSha256 = (Get-FileHash -LiteralPath $binding.receiptPath).Hash
    $badManifest.controllerBundleBinding = $badLock.controllerBundleBinding
    $refused = $false
    try { $null = & $copiedModule { param($l,$m) Assert-MO2ControllerBundleBinding -Data $l -Manifest $m } $badLock $badManifest } catch { $refused = $_.Exception.Message -match 'Required controller dependency is missing' }
    Assert-Bundle $refused 'versioned required closure refuses mutually agreeing omitted dependency'
} finally { [IO.File]::WriteAllBytes($binding.receiptPath, $originalReceipt) }
$released = & $controllerPath release -SessionId $sessionId -Compact -NoExit | ConvertFrom-Json -Depth 70
Assert-Bundle ($released.ok) 'synthetic session released through copied public controller'
Remove-Module MO2Control -Force
Import-Module (Join-Path $toolRoot 'mo2-control/MO2Control.psm1') -Force
$releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
Assert-Bundle ($releasedAccess.ok) 'synthetic access released; no real lease used'
[pscustomobject]@{ ok = $true; assertions = $bundleChecks.Count; checks = @($bundleChecks); bundleBinding = $binding; positivePreview = $good; missingDependencyPreview = $missing; actualDriftPreview = $drift; scope = 'Synthetic prepared workspace/cache; real public prepare and fresh copied-controller launch WhatIf; producer moved unavailable; zero MO2/game/runtime dispatch.' } | ConvertTo-Json -Depth 70
