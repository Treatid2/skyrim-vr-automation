[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('steamvr-null-control-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedFixture = [IO.Path]::GetFullPath($fixture)
if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Fixture escaped the temporary directory: $resolvedFixture"
}
$failures = [Collections.Generic.List[string]]::new()
$passes = [Collections.Generic.List[string]]::new()
$priorTransactionRoot = $env:CSX_STEAMVR_TRANSACTION_ROOT

function Assert-Test([bool]$Condition, [string]$Name) {
    if ($Condition) { $passes.Add($Name) } else { $failures.Add($Name) }
}

$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if ($windowsPowerShell) {
    $legacyResult = & $windowsPowerShell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry inspect -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $legacyResult.ok -and $legacyResult.state -eq 'unsupported-powershell-version' -and $legacyResult.errors[0] -match 'pwsh\.exe') 'Windows PowerShell receives an explicit PowerShell 7 compatibility failure'
}

try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $settingsPath = Join-Path $fixture 'steamvr.vrsettings'
    $transactionRoot = Join-Path $fixture 'target-control'
    $env:CSX_STEAMVR_TRANSACTION_ROOT = $transactionRoot
    $profilePath = Join-Path $fixture 'null.json'
    $evidence = Join-Path $fixture 'evidence'
    $isolationEvidence = Join-Path $fixture 'evidence-isolation'
    $failureEvidence = Join-Path $fixture 'evidence-failure'
    $steamVrRoot = Join-Path $fixture 'SteamVR'
    $startupPath = Join-Path $steamVrRoot 'bin\win64\vrstartup.exe'
    $serverLogPath = Join-Path $fixture 'vrserver.txt'
    $openVrPathsPath = Join-Path $fixture 'openvrpaths.vrpath'
    $externalDriverRoot = Join-Path $fixture 'VirtualDesktopDriver'
    $headPoseDriverRoot = Join-Path $fixture 'HeadPoseDriver'
    New-Item -ItemType Directory -Path $externalDriverRoot | Out-Null
    New-Item -ItemType Directory -Path $headPoseDriverRoot | Out-Null
    [ordered]@{ name = 'codex_head_pose'; alwaysActivate = $true; redirectsDisplay = $false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $headPoseDriverRoot 'driver.vrdrivermanifest') -Encoding utf8
    [ordered]@{ version = 1; external_drivers = @($headPoseDriverRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    New-Item -ItemType Directory -Path $evidence | Out-Null
    New-Item -ItemType Directory -Path $isolationEvidence | Out-Null
    New-Item -ItemType Directory -Path $failureEvidence | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $startupPath) -Force | Out-Null
    [IO.File]::WriteAllBytes($startupPath, [byte[]]@(0))
    $originalText = "{`r`n  `"steamvr`": { `"enableHomeApp`": true },`r`n  `"unrelated`": { `"value`": 7 }`r`n}`r`n"
    [IO.File]::WriteAllText($settingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    [ordered]@{
        steamvr = [ordered]@{ forcedDriver = 'null'; requireHmd = $false; activateMultipleDrivers = $true; enableHomeApp = $false }
        dashboard = [ordered]@{ enableDashboard = $false }
        driver_null = [ordered]@{ enable = $true; serialNumber = 'Fixture'; modelNumber = 'Fixture'; windowWidth = 2160; windowHeight = 1200; renderWidth = 1512; renderHeight = 1680; displayFrequency = 90.0 }
        driver_codex_head_pose = [ordered]@{ enable = $true; serialNumber = 'CSX-NULL-HMD-POSE-1'; modelNumber = 'Fixture Pose'; positionX = 0.0; eyeHeightMeters = 1.68; positionZ = 0.0; yawDegrees = 0.0; pitchDegrees = 0.0; rollDegrees = 0.0 }
        TrackingOverrides = [ordered]@{ '/devices/codex_head_pose/CSX-NULL-HMD-POSE-1' = '/user/head' }
        headPoseProviderContract = [ordered]@{ driverName = 'codex_head_pose'; registeredDevicePath = '/devices/codex_head_pose/CSX-NULL-HMD-POSE-1'; semanticTarget = '/user/head'; sharedMemoryName = "Local\CSXVRHeadPose-fixture-$([guid]::NewGuid().ToString('N'))"; sharedMemoryVersion = 1; minimumQualifiedEyeHeightMeters = 1.0; maximumQualifiedEyeHeightMeters = 2.5 }
        automationInputContract = [ordered]@{ hmdPoseProvider = 'codex-head-pose-v2'; hmdPoseControl = 'shared-memory-v2'; controllerInput = 'unavailable'; dashboardInput = 'disabled'; replayReady = $false; measurementReady = $false; qualificationRequired = 'fixture qualification' }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $profilePath -Encoding utf8

    $inspectBefore = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($inspectBefore.ok -and $inspectBefore.state -eq 'null-inactive') 'inspect identifies inactive null profile'
    Assert-Test ((Test-Path -LiteralPath $inspectBefore.data.targetControl.directory -PathType Container) -and $inspectBefore.data.targetControl.key -match '^[0-9a-f]{64}$') 'canonical live targets map to a deterministic target-owned control directory'

    $heldLock = [IO.File]::Open([string]$inspectBefore.data.targetControl.lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $contended = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -TransactionLockTimeoutMilliseconds 100 -Compact -NoExit | ConvertFrom-Json
        Assert-Test (-not $contended.ok -and $contended.errors[0] -match 'target transaction lock') 'a second caller cannot inspect or mutate the same live targets while their bounded lock is held'
    }
    finally { $heldLock.Dispose() }

    $sourceText = [IO.File]::ReadAllText($entry)
    Assert-Test ($sourceText -notmatch '\.ReadToEnd\(' -and $sourceText -match 'LogTailMaxBytes') 'SteamVR readiness polling uses a bounded byte tail instead of whole-log reads'

    $stop = & $entry stop -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($stop.ok -and $stop.state -eq 'already-stopped') 'stop recognizes an already closed SteamVR state'

    $dry = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($dry.ok -and $dry.state -eq 'dry-run') 'apply dry-run succeeds'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $evidence 'steamvr.vrsettings.before'))) 'apply dry-run creates no backup'

    $applied = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -Compact | ConvertFrom-Json
    Assert-Test ($applied.ok -and $applied.state -eq 'null-applied') 'apply writes effective null profile'
    if (-not $applied.ok) { throw "Fixture apply failed: $($applied.errors -join '; ')" }
    $appliedJson = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ($appliedJson['unrelated']['value'] -eq 7) 'apply preserves unrelated settings'
    Assert-Test ($appliedJson['dashboard']['enableDashboard'] -eq $false) 'apply disables the dashboard generic-HMD input route'
    Assert-Test ($appliedJson['driver_codex_head_pose']['eyeHeightMeters'] -eq 1.68 -and $appliedJson['TrackingOverrides']['/devices/codex_head_pose/CSX-NULL-HMD-POSE-1'] -eq '/user/head') 'apply configures the synthetic head pose and semantic override'
    Assert-Test (Test-Path -LiteralPath (Join-Path $evidence 'steamvr-null-receipt.json')) 'apply writes hash receipt'
    $appliedReceipt = Get-Content -LiteralPath (Join-Path $evidence 'steamvr-null-receipt.json') -Raw | ConvertFrom-Json
    Assert-Test ((Test-Path -LiteralPath $appliedReceipt.profileEvidencePath -PathType Leaf) -and (Get-FileHash -LiteralPath $appliedReceipt.profileEvidencePath -Algorithm SHA256).Hash -eq $appliedReceipt.profileSha256) 'apply retains an exact receipt-bound null profile in stable evidence'
    $appliedText = [IO.File]::ReadAllText($settingsPath)

    $secondCallerApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($secondCallerApply.ok -and $secondCallerApply.state -eq 'already-applied' -and $secondCallerApply.data.evidenceDirectory -eq [IO.Path]::GetFullPath($evidence)) 'a second evidence directory cannot establish a false baseline over an active authoritative apply transaction'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $isolationEvidence 'steamvr.vrsettings.before'))) 'already-applied ownership check creates no second backup'

    $wrongEvidenceStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongEvidenceStart.ok -and $wrongEvidenceStart.errors[0] -match 'owned by a different evidence directory') 'start refuses a caller-selected evidence directory that does not own the live transaction'

    $otherSettingsPath = Join-Path $fixture 'other-steamvr.vrsettings'
    [IO.File]::WriteAllText($otherSettingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    $wrongPathRestore = & $entry restore -SettingsPath $otherSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongPathRestore.ok -and $wrongPathRestore.state -eq 'blocked' -and $wrongPathRestore.errors[0] -match 'settings path') 'restore refuses a settings path different from its apply receipt'

    $movedProfilePath = "$profilePath.moved"
    Move-Item -LiteralPath $profilePath -Destination $movedProfilePath
    try {
        $cacheIndependentRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
        Assert-Test ($cacheIndependentRestore.ok -and $cacheIndependentRestore.data.settingsRestoreValidation.authorized) 'restore survives removal of the original versioned profile path'
    }
    finally { Move-Item -LiteralPath $movedProfilePath -Destination $profilePath }

    [IO.File]::AppendAllText($settingsPath, "`n")
    $formattingRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($formattingRestore.ok -and $formattingRestore.data.settingsRestoreValidation.formattingOnlyDriftAccepted -and $formattingRestore.data.settingsRestoreValidation.authorizationRoute -eq 'semantic-formatting-only') 'restore accepts formatting-only SteamVR settings drift'

    $runtimeDrift = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    $runtimeDrift['GpuSpeed'] = [ordered]@{ gpuSpeed0 = 1234; gpuSpeedCount = 1 }
    $runtimeDrift['LastKnown'] = [ordered]@{ HMDManufacturer = 'Null'; HMDModel = 'Null Model' }
    $runtimeDrift | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    $runtimeRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($runtimeRestore.ok -and $runtimeRestore.data.settingsRestoreValidation.runtimeManagedOnlyDriftAccepted -and $runtimeRestore.data.settingsRestoreValidation.authorizationRoute -eq 'controlled-contract-plus-runtime-managed-fields') 'restore accepts SteamVR-managed GpuSpeed and LastKnown drift while controlled settings still match'

    $controlledDrift = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    $controlledDrift['dashboard']['enableDashboard'] = $true
    $controlledDrift | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    $controlledDriftRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $controlledDriftRestore.ok -and $controlledDriftRestore.state -eq 'blocked' -and $controlledDriftRestore.errors[0] -match 'dashboard.enableDashboard') 'restore refuses drift in a controller-owned SteamVR setting'

    $unclassifiedDrift = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    $unclassifiedDrift['dashboard']['enableDashboard'] = $false
    $unclassifiedDrift['unrelated']['newValue'] = 8
    $unclassifiedDrift | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    $unclassifiedDriftRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $unclassifiedDriftRestore.ok -and $unclassifiedDriftRestore.state -eq 'blocked' -and $unclassifiedDriftRestore.errors[0] -match 'unrelated.newValue') 'restore refuses unclassified SteamVR settings drift'
    [IO.File]::WriteAllText($settingsPath, $appliedText, [Text.UTF8Encoding]::new($false))

    $inspectConfigured = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($inspectConfigured.ok -and $inspectConfigured.state -eq 'null-configured-runtime-stopped' -and -not $inspectConfigured.data.runtime.active) 'inspect distinguishes configured settings from a proven runtime'
    Assert-Test (-not $inspectConfigured.data.inputContract.replayReady -and $inspectConfigured.data.inputContract.controllerInput -eq 'unavailable' -and $inspectConfigured.data.inputContract.hmdPoseControl -eq 'shared-memory-v2') 'inspect exposes controlled HMD pose while keeping controller replay unavailable'

    $startDry = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($startDry.ok -and $startDry.state -eq 'dry-run' -and $startDry.data.startupPath -eq $startupPath) 'start dry-run validates the configured transaction and exact startup path'

    [ordered]@{ name = 'VirtualDesktop'; alwaysActivate = $true; redirectsDisplay = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $externalDriverRoot 'driver.vrdrivermanifest') -Encoding utf8
    [ordered]@{ version = 1; external_drivers = @($headPoseDriverRoot, $externalDriverRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    $conflictInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($conflictInspect.ok -and $conflictInspect.state -eq 'external-driver-conflict' -and $conflictInspect.data.externalDrivers.conflicts[0].name -eq 'VirtualDesktop') 'inspect reports exact external display-driver conflicts'
    $conflictStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $conflictStart.ok -and $conflictStart.state -eq 'external-driver-conflict') 'start refuses an external OpenVR display redirector'
    $conflictOverrideStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -AllowExternalDisplayRedirector -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($conflictOverrideStart.ok -and $conflictOverrideStart.state -eq 'dry-run' -and $conflictOverrideStart.data.externalDisplayRedirectorAllowed) 'explicit diagnostic override permits a dry-run while retaining the driver inventory'

    $restored = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -Compact | ConvertFrom-Json
    Assert-Test ($restored.ok -and $restored.state -eq 'restored' -and $restored.data.backupRetained) 'restore succeeds and retains backup'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'restore is exact-byte identical'

    $openVrTextBeforeIsolation = [IO.File]::ReadAllText($openVrPathsPath)
    $isolationDry = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -IsolateExternalDisplayRedirectors -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolationDry.ok -and $isolationDry.state -eq 'dry-run' -and $isolationDry.data.externalDriverIsolation.targets[0].name -eq 'VirtualDesktop') 'isolation dry-run identifies the sole exact redirector'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $isolationEvidence 'openvrpaths.vrpath.before'))) 'isolation dry-run creates no OpenVR registration backup'

    $isolatedApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -IsolateExternalDisplayRedirectors -Compact | ConvertFrom-Json
    Assert-Test ($isolatedApply.ok -and $isolatedApply.state -eq 'null-applied' -and $isolatedApply.data.externalDriverIsolation.enabled) 'apply transaction isolates the exact external display redirector'
    Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$isolatedApply.data.externalDriverIsolation.semanticSha256Before) -and -not [string]::IsNullOrWhiteSpace([string]$isolatedApply.data.externalDriverIsolation.semanticSha256Isolated)) 'isolation receipt records exact and semantic registration hashes'
    if (-not $isolatedApply.ok) { throw "Fixture isolation apply failed: $($isolatedApply.errors -join '; ')" }
    $isolatedPaths = Get-Content -LiteralPath $openVrPathsPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test (@($isolatedPaths['external_drivers']).Count -eq 1 -and [IO.Path]::GetFullPath([string]$isolatedPaths['external_drivers'][0]) -eq [IO.Path]::GetFullPath($headPoseDriverRoot)) 'isolation retains the non-redirecting head-pose driver only'
    Assert-Test (Test-Path -LiteralPath (Join-Path $isolationEvidence 'openvrpaths.vrpath.before')) 'isolation writes an exact OpenVR registration backup'

    $isolatedInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($isolatedInspect.ok -and $isolatedInspect.state -eq 'null-configured-runtime-stopped' -and $isolatedInspect.data.externalDrivers.conflicts.Count -eq 0) 'inspect accepts the conflict-free isolated registration state'
    $isolatedStartDry = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolatedStartDry.ok -and $isolatedStartDry.state -eq 'dry-run' -and $isolatedStartDry.data.externalDriverIsolation.enabled -and -not $isolatedStartDry.data.inputContract.measurementReady) 'isolated start validates its receipt while runtime readiness remains fail-closed'

    $isolatedBytes = [IO.File]::ReadAllBytes($openVrPathsPath)
    [IO.File]::WriteAllText($openVrPathsPath, $openVrTextBeforeIsolation, [Text.UTF8Encoding]::new($false))
    $baselineRestoredDry = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($baselineRestoredDry.ok -and $baselineRestoredDry.data.externalDriverIsolationValidation.baselineAlreadyRestored) 'restore accepts OpenVR registrations only when they already match the exact retained pre-isolation baseline'
    [IO.File]::WriteAllBytes($openVrPathsPath, $isolatedBytes)

    $isolatedText = (Get-Content -LiteralPath $openVrPathsPath -Raw | ConvertFrom-Json -AsHashtable | ConvertTo-Json -Depth 8 -Compress) + "`r`n"
    [IO.File]::WriteAllText($openVrPathsPath, $isolatedText, [Text.UTF8Encoding]::new($false))
    $formatStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($formatStart.ok -and $formatStart.state -eq 'dry-run' -and $formatStart.data.externalDriverIsolationValidation.formattingOnlyDriftAccepted -and $formatStart.data.externalDriverIsolationValidation.expectationSource -eq 'exact-backup-minus-unique-targets') 'start accepts formatting-only drift using a backup-derived expectation'

    $isolationReceiptPath = Join-Path $isolationEvidence 'steamvr-null-receipt.json'
    $isolationReceipt = Get-Content -LiteralPath $isolationReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    $recordedSemanticHash = [string]$isolationReceipt['externalDriverIsolation']['semanticSha256Isolated']
    $isolationReceipt['externalDriverIsolation']['semanticSha256Isolated'] = '00'
    $isolationReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $isolationReceiptPath -Encoding utf8
    $tamperedSemanticStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $tamperedSemanticStart.ok -and $tamperedSemanticStart.errors[0] -match 'receipt semantic hash') 'receipt semantic hash is corroboration, never the authoritative expected state'

    $isolationReceipt['externalDriverIsolation']['semanticSha256Isolated'] = $recordedSemanticHash
    $originalIsolationTargets = @($isolationReceipt['externalDriverIsolation']['targets'])
    $isolationReceipt['externalDriverIsolation']['targets'] = @($originalIsolationTargets[0], $originalIsolationTargets[0])
    $isolationReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $isolationReceiptPath -Encoding utf8
    $duplicateTargetStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $duplicateTargetStart.ok -and $duplicateTargetStart.errors[0] -match 'duplicate normalized target') 'duplicate receipt targets cannot satisfy backup reconstruction'

    $isolationReceipt['externalDriverIsolation']['targets'] = @($originalIsolationTargets)
    $isolationReceipt['externalDriverIsolation'].Remove('semanticSha256Before')
    $isolationReceipt['externalDriverIsolation'].Remove('semanticSha256Isolated')
    $isolationReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $isolationReceiptPath -Encoding utf8
    $legacyFormatStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($legacyFormatStart.ok -and $legacyFormatStart.data.externalDriverIsolationValidation.formattingOnlyDriftAccepted) 'legacy byte-only receipt reconstructs the isolated semantic state from its exact backup'

    $failedRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -InternalTestFailurePoint restore-after-settings -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedRestore.ok -and $failedRestore.errors[0] -match 'exact applied state was restored') 'two-file restore failure reports verified rollback to the applied state'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $appliedText -and [IO.File]::ReadAllText($openVrPathsPath) -ceq $isolatedText) 'two-file restore failure leaves neither target partially restored'
    $postRollbackApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $failureEvidence -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($postRollbackApply.ok -and $postRollbackApply.state -eq 'already-applied' -and $postRollbackApply.data.evidenceDirectory -eq [IO.Path]::GetFullPath($isolationEvidence)) 'a rolled-back restore retains authoritative ownership of the applied state'

    $drift = Get-Content -LiteralPath $openVrPathsPath -Raw | ConvertFrom-Json -AsHashtable
    $drift['unrelated_test_drift'] = $true
    $drift | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    $driftStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $driftStart.ok -and $driftStart.state -eq 'external-driver-isolation-drift') 'start refuses OpenVR registration drift after isolation'
    $driftRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $driftRestore.ok -and $driftRestore.state -eq 'blocked' -and $driftRestore.errors[0] -match 'registration file changed') 'restore refuses to overwrite unclassified OpenVR registration drift'

    [IO.File]::WriteAllText($openVrPathsPath, $isolatedText, [Text.UTF8Encoding]::new($false))
    $isolatedRestoreDry = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestoreDry.ok -and $isolatedRestoreDry.data.externalDriverIsolation.enabled -and $isolatedRestoreDry.data.wouldRestoreOpenVRPaths) 'restore dry-run reports exact external-driver restoration'
    $isolatedRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestore.ok -and $isolatedRestore.state -eq 'restored' -and $isolatedRestore.data.openVRPathsRestoredSha256 -and $isolatedRestore.data.externalDriverIsolationValidation.formattingOnlyDriftAccepted) 'restore reinstates the exact external-driver registration transaction after formatting-only drift'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'isolation restore keeps SteamVR settings exact-byte identical'
    Assert-Test ([IO.File]::ReadAllText($openVrPathsPath) -ceq $openVrTextBeforeIsolation) 'isolation restore keeps OpenVR registrations exact-byte identical'

    $isolatedRestoreAgain = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestoreAgain.ok -and $isolatedRestoreAgain.state -eq 'already-restored') 'restore retry recognizes the committed exact baseline without rewriting it'

    $failedApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $failureEvidence -IsolateExternalDisplayRedirectors -InternalTestFailurePoint apply-after-openvr -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedApply.ok -and $failedApply.errors[0] -match 'every exact backup was restored') 'two-file apply failure reports verified rollback to the original state'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText -and [IO.File]::ReadAllText($openVrPathsPath) -ceq $openVrTextBeforeIsolation) 'two-file apply failure leaves neither target partially mutated'

    $legacyReconcileBackup = Join-Path $failureEvidence 'openvrpaths.vrpath.reconcile.before'
    Copy-Item -LiteralPath $openVrPathsPath -Destination $legacyReconcileBackup
    $legacyReconcile = [ordered]@{
        contractVersion = '1.0.0'; operation = 'apply-reconcile'; transactionId = [guid]::NewGuid().ToString('N'); phase = 'committed'
        settingsPath = [IO.Path]::GetFullPath($settingsPath); openVRPathsPath = [IO.Path]::GetFullPath($openVrPathsPath)
        evidenceDirectory = [IO.Path]::GetFullPath($failureEvidence); evidenceJournalPath = [IO.Path]::GetFullPath((Join-Path $failureEvidence 'steamvr-null-apply-reconcile.journal.json'))
        rollbackTargets = @([ordered]@{ name = 'openvr-registrations'; path = [IO.Path]::GetFullPath($openVrPathsPath); backupPath = [IO.Path]::GetFullPath($legacyReconcileBackup); expectedHash = (Get-FileHash -LiteralPath $legacyReconcileBackup -Algorithm SHA256).Hash })
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null; committedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $legacyReconcile | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$inspectBefore.data.targetControl.journalPath) -Encoding utf8
    $legacyReconcileInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($legacyReconcileInspect.ok -and $legacyReconcileInspect.data.recoveredTransaction.operation -eq 'apply-reconcile') 'inspect accepts a committed legacy apply-reconcile journal whose sole rollback target is OpenVR registrations'

    $legacyReconcile['rollbackTargets'] = @()
    $legacyReconcile | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$inspectBefore.data.targetControl.journalPath) -Encoding utf8
    $invalidLegacyReconcile = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $invalidLegacyReconcile.ok -and $invalidLegacyReconcile.errors[0] -match 'OpenVR registrations rollback target') 'legacy apply-reconcile compatibility still requires its exact OpenVR rollback target'

    $recoveryEvidenceA = Join-Path $fixture 'recovery-evidence-a'
    $recoveryEvidenceB = Join-Path $fixture 'recovery-evidence-b'
    New-Item -ItemType Directory -Path $recoveryEvidenceA, $recoveryEvidenceB | Out-Null
    $recoveryBackup = Join-Path $recoveryEvidenceA 'steamvr.vrsettings.before'
    [IO.File]::WriteAllText($recoveryBackup, $originalText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($settingsPath, $appliedText, [Text.UTF8Encoding]::new($false))
    $recoveryMirror = Join-Path $recoveryEvidenceA 'steamvr-null-apply.journal.json'
    $unrelatedTarget = Join-Path $fixture 'unrelated-target.txt'
    $unrelatedBackup = Join-Path $recoveryEvidenceA 'unrelated-target.before'
    [IO.File]::WriteAllText($unrelatedTarget, 'live', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($unrelatedBackup, 'backup', [Text.UTF8Encoding]::new($false))
    $tamperedJournal = [ordered]@{
        contractVersion = '1.0.0'; operation = 'apply'; transactionId = [guid]::NewGuid().ToString('N'); phase = 'settings-applied-uncommitted'
        settingsPath = [IO.Path]::GetFullPath($settingsPath); openVRPathsPath = $null
        evidenceDirectory = [IO.Path]::GetFullPath($recoveryEvidenceA); evidenceJournalPath = [IO.Path]::GetFullPath($recoveryMirror)
        rollbackTargets = @([ordered]@{ name = 'unrelated'; path = [IO.Path]::GetFullPath($unrelatedTarget); backupPath = [IO.Path]::GetFullPath($unrelatedBackup); expectedHash = (Get-FileHash -LiteralPath $unrelatedBackup -Algorithm SHA256).Hash })
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
    }
    $tamperedJournal | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$inspectBefore.data.targetControl.journalPath) -Encoding utf8
    $tamperedRecovery = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $recoveryEvidenceB -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $tamperedRecovery.ok -and $tamperedRecovery.errors[0] -match 'out-of-contract rollback target' -and [IO.File]::ReadAllText($unrelatedTarget) -ceq 'live') 'authoritative recovery rejects a journal that names a live target outside its canonical lock domain'

    $pending = [ordered]@{
        contractVersion = '1.0.0'; operation = 'apply'; transactionId = [guid]::NewGuid().ToString('N'); phase = 'settings-applied-uncommitted'
        settingsPath = [IO.Path]::GetFullPath($settingsPath); openVRPathsPath = $null
        evidenceDirectory = [IO.Path]::GetFullPath($recoveryEvidenceA); evidenceJournalPath = [IO.Path]::GetFullPath($recoveryMirror)
        rollbackTargets = @([ordered]@{ name = 'steamvr-settings'; path = [IO.Path]::GetFullPath($settingsPath); backupPath = [IO.Path]::GetFullPath($recoveryBackup); expectedHash = (Get-FileHash -LiteralPath $recoveryBackup -Algorithm SHA256).Hash })
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
    }
    $pending | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath ([string]$inspectBefore.data.targetControl.journalPath) -Encoding utf8
    $pending | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recoveryMirror -Encoding utf8
    $crossEvidenceRecovery = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $recoveryEvidenceB -Compact | ConvertFrom-Json
    $recoveredAuthority = Get-Content -LiteralPath ([string]$inspectBefore.data.targetControl.journalPath) -Raw | ConvertFrom-Json
    $recoveredMirror = Get-Content -LiteralPath $recoveryMirror -Raw | ConvertFrom-Json
    Assert-Test ($crossEvidenceRecovery.ok -and $crossEvidenceRecovery.data.recoveredTransaction.phase -eq 'recovered' -and [IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'a caller with a different evidence directory recovers the authoritative pending target transaction before inspection'
    Assert-Test ($recoveredAuthority.phase -eq 'recovered' -and $recoveredMirror.phase -eq 'recovered') 'authoritative recovery is mirrored back to the secondary evidence journal'
}
finally {
    $env:CSX_STEAMVR_TRANSACTION_ROOT = $priorTransactionRoot
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) { exit 1 }
