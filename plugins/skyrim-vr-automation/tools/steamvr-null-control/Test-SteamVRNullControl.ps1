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
    $mo2ProfilePath = Join-Path $fixture 'MO2Profile'
    $mo2ModsPath = Join-Path $fixture 'mods'
    $ocuModPath = Join-Path $mo2ModsPath 'Renamed OCU Root Provider'
    $externalDriverRoot = Join-Path $fixture 'VirtualDesktopDriver'
    $headPoseDriverRoot = Join-Path $fixture 'HeadPoseDriver'
    New-Item -ItemType Directory -Path $externalDriverRoot | Out-Null
    New-Item -ItemType Directory -Path $headPoseDriverRoot | Out-Null
    New-Item -ItemType Directory -Path $mo2ProfilePath | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ocuModPath 'Root') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $mo2ProfilePath 'modlist.txt'), "+Renamed OCU Root Provider`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $ocuModPath 'Root\openvr_api.dll'), [byte[]]@(1, 2, 3))
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

    $knownOwner = '{"pid":4242,"processStartUtc":"2026-09-01T00:00:00Z"}'
    [IO.File]::WriteAllText([string]$inspectBefore.data.targetControl.lockPath, $knownOwner, [Text.UTF8Encoding]::new($false))
    $heldLock = [IO.File]::Open([string]$inspectBefore.data.targetControl.lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $contended = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -TransactionLockTimeoutMilliseconds 100 -Compact -NoExit | ConvertFrom-Json
        Assert-Test (-not $contended.ok -and $contended.errors[0] -match 'target transaction lock' -and $contended.errors[0] -match '4242') 'a second caller reports attributable owner evidence while the bounded target lock is held'
    }
    finally { $heldLock.Dispose() }

    $sourceText = [IO.File]::ReadAllText($entry)
    Assert-Test ($sourceText -notmatch '\.ReadToEnd\(' -and $sourceText -match 'LogTailMaxBytes') 'SteamVR readiness polling uses a bounded byte tail instead of whole-log reads'
    Assert-Test ($sourceText -notmatch 'deadline expired before opening the log') 'an expired poll budget still permits one final bounded log read'

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$parseErrors)
    Assert-Test ($parseErrors.Count -eq 0) 'SteamVR null controller parses before fixture helper extraction'
    foreach ($functionName in @('Get-SharedTextTail', 'Get-LogTimestampUtc', 'Get-NullRuntimeLogMarkers')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
        if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    $minimumUtc = [DateTime]::Parse('2026-09-01T05:09:55Z').ToUniversalTime()
    $classicMarkers = Get-NullRuntimeLogMarkers -MinimumUtc $minimumUtc -SerialNumber 'CSX Null HMD' -Lines @(
        'Tue Sep 01 2026 06:09:59.502 [Info] - Loaded server driver null (IServerTrackedDeviceProvider_004) from C:\SteamVR\drivers\null\bin\win64\driver_null.dll',
        'Tue Sep 01 2026 06:09:59.502 [Info] - Active HMD set to null.CSX Null HMD',
        'Tue Sep 01 2026 06:09:59.515 [Info] - codex_head_pose: codex_head_pose: registered synthetic head-pose device at configured standing pose',
        'Tue Sep 01 2026 06:09:59.515 [Info] - Loaded server driver codex_head_pose (IServerTrackedDeviceProvider_004) from C:\Drivers\driver_codex_head_pose.dll'
    )
    Assert-Test ($classicMarkers.driverLoaded -and $classicMarkers.activeHmd -and $classicMarkers.headPoseDriverLoaded -and $classicMarkers.headPoseDeviceRegistered) 'classic current-session null and head-pose vocabulary remains qualified'
    $existingMarkers = Get-NullRuntimeLogMarkers -MinimumUtc $minimumUtc -SerialNumber 'CSX Null HMD' -Lines @(
        'Tue Sep 01 2026 06:09:54.000 [Info] - Using existing HMD null.CSX Null HMD',
        'Tue Sep 01 2026 06:09:59.643 [Info] - Using existing HMD null.CSX Null HMD'
    )
    Assert-Test ($existingMarkers.driverLoaded.vocabulary -eq 'active-hmd-implies-null-driver' -and $existingMarkers.activeHmd.vocabulary -eq 'existing-hmd' -and $existingMarkers.recentEvidence.Count -eq 1) 'Valve existing-HMD vocabulary proves the exact current-session null route and excludes stale lines'
    $largeLogPath = Join-Path $fixture 'bounded-large-vrserver.txt'
    $largeLines = 1..5000 | ForEach-Object { "Tue Sep 01 2026 06:10:00.000 [Info] - filler $_" }
    $largeLines[-1] = 'Tue Sep 01 2026 06:10:01.000 [Info] - Using existing HMD null.CSX Null HMD'
    [IO.File]::WriteAllLines($largeLogPath, $largeLines, [Text.UTF8Encoding]::new($false))
    $script:SharedTextTailState = @{}
    $expiredTail = @(Get-SharedTextTail -Path $largeLogPath -Count 2000 -MaxBytes 262144 -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1)))
    Assert-Test ($expiredTail[-1] -match 'Using existing HMD') 'a pre-existing large log yields a bounded final tail after the readiness deadline'

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
    $routeConflict = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -MO2ProfilePath $mo2ProfilePath -MO2ModsPath $mo2ModsPath -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $routeConflict.ok -and $routeConflict.state -eq 'application-route-conflict' -and $routeConflict.data.applicationRoute.providers[0].modName -eq 'Renamed OCU Root Provider') 'null-HMD start rejects a renamed enabled root OpenVR provider by exact profile provenance'
    [IO.File]::WriteAllText((Join-Path $mo2ProfilePath 'modlist.txt'), "-Renamed OCU Root Provider`r`n", [Text.UTF8Encoding]::new($false))
    $routeQualified = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -MO2ProfilePath $mo2ProfilePath -MO2ModsPath $mo2ModsPath -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($routeQualified.ok -and $routeQualified.data.applicationRoute.evaluated -and $routeQualified.data.applicationRoute.qualified) 'null-HMD start qualifies an exact profile with no enabled root OpenVR provider'

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

    $mixedSettingsPath = Join-Path $fixture 'mixed-steamvr.vrsettings'
    $mixedOpenVRPathsPath = Join-Path $fixture 'mixed-openvrpaths.vrpath'
    $mixedEvidence = Join-Path $fixture 'evidence-mixed-targets'
    New-Item -ItemType Directory -Path $mixedEvidence | Out-Null
    [IO.File]::WriteAllText($mixedSettingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($mixedOpenVRPathsPath, $openVrTextBeforeIsolation, [Text.UTF8Encoding]::new($false))
    $mixedApply = & $entry apply -SettingsPath $mixedSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $mixedOpenVRPathsPath -EvidenceDirectory $mixedEvidence -IsolateExternalDisplayRedirectors -Compact | ConvertFrom-Json
    Assert-Test ($mixedApply.ok -and $mixedApply.state -eq 'null-applied') 'mixed-target fixture begins from a committed isolated apply transaction'

    Copy-Item -LiteralPath (Join-Path $mixedEvidence 'openvrpaths.vrpath.before') -Destination $mixedOpenVRPathsPath -Force
    $partialRestoreDry = & $entry restore -SettingsPath $mixedSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $mixedOpenVRPathsPath -EvidenceDirectory $mixedEvidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($partialRestoreDry.ok -and $partialRestoreDry.data.externalDriverIsolationValidation.state -eq 'baseline' -and $partialRestoreDry.data.wouldRestoreSettings -and -not $partialRestoreDry.data.wouldRestoreOpenVRPaths) 'restore accepts an exact OpenVR preimage while SteamVR settings remain applied'
    $mixedReapply = & $entry apply -SettingsPath $mixedSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $mixedOpenVRPathsPath -EvidenceDirectory $mixedEvidence -Compact | ConvertFrom-Json
    Assert-Test ($mixedReapply.ok -and $mixedReapply.state -eq 'null-reconciled' -and $mixedReapply.data.externalDriverIsolationValidation.state -eq 'isolated') 'apply transactionally re-isolates an exact externally restored OpenVR target'

    Copy-Item -LiteralPath (Join-Path $mixedEvidence 'steamvr.vrsettings.before') -Destination $mixedSettingsPath -Force
    $mixedRestore = & $entry restore -SettingsPath $mixedSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $mixedOpenVRPathsPath -EvidenceDirectory $mixedEvidence -Compact | ConvertFrom-Json
    Assert-Test ($mixedRestore.ok -and $mixedRestore.state -eq 'restored' -and $mixedRestore.data.settingsRestoreValidation.authorizationRoute -eq 'exact-baseline-bytes') 'restore completes only the still-isolated OpenVR target when SteamVR settings are already exact baseline bytes'
    Assert-Test ([IO.File]::ReadAllText($mixedSettingsPath) -ceq $originalText -and [IO.File]::ReadAllText($mixedOpenVRPathsPath) -ceq $openVrTextBeforeIsolation) 'mixed-target reconciliation converges both files to their exact pre-apply bytes'

    $failedApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $failureEvidence -IsolateExternalDisplayRedirectors -InternalTestFailurePoint apply-after-openvr -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedApply.ok -and $failedApply.errors[0] -match 'every exact backup was restored') 'two-file apply failure reports verified rollback to the original state'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText -and [IO.File]::ReadAllText($openVrPathsPath) -ceq $openVrTextBeforeIsolation) 'two-file apply failure leaves neither target partially mutated'

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
