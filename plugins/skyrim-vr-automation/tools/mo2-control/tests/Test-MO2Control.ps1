# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [switch]$IncludeLive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packageRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $packageRoot 'MO2Control.psm1') -Force

$failures = [System.Collections.Generic.List[string]]::new()
$passes = [System.Collections.Generic.List[string]]::new()

function Assert-MO2Test {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Condition) {
        $passes.Add($Name)
    }
    else {
        $failures.Add($Name)
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-control-test-' + [guid]::NewGuid().ToString('N'))
try {
    $mo2Root = Join-Path $fixture 'MO2'
    $profileRoot = Join-Path $mo2Root 'profiles'
    $profile = Join-Path $profileRoot 'Codex'
    $overwrite = Join-Path $mo2Root 'overwrite'
    $rootBuilderDefinitions = Join-Path $mo2Root 'rootbuilder-definitions'
    $rootBuilderData = Join-Path $mo2Root 'rootbuilder-data'
    $gameRoot = Join-Path $fixture 'Game'
    $staging = Join-Path $fixture 'staging'
    $archive = Join-Path $fixture 'archive'
    $sessionRoot = Join-Path $fixture 'sessions'

    foreach ($directory in @($profile, $overwrite, $rootBuilderDefinitions, $rootBuilderData, $gameRoot, $staging, $archive, $sessionRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $mo2Exe = Join-Path $mo2Root 'ModOrganizer.exe'
    $loader = Join-Path $gameRoot 'sksevr_loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null
    New-Item -ItemType File -Path $loader -Force | Out-Null

    $definition = Join-Path $rootBuilderDefinitions 'rootbuilder_defaults.json'
    $gameData = Join-Path $rootBuilderData 'GameData.json'
    '{}' | Set-Content -LiteralPath $definition -Encoding utf8
    '{}' | Set-Content -LiteralPath $gameData -Encoding utf8

    $ini = Join-Path $mo2Root 'ModOrganizer.ini'
    @"
[General]
selected_profile=@ByteArray(Codex)
[customExecutables]
1\title=@ByteArray(Launch MGO - Do Not Unlock)
1\binary=@ByteArray($loader)
1\arguments=@ByteArray()
1\workingDirectory=@ByteArray($gameRoot)
"@ | Set-Content -LiteralPath $ini -Encoding utf8

    $configPath = Join-Path $fixture 'config.json'
    [ordered]@{
        contractVersion = '0.3.0'
        machine = 'fixture'
        mo2 = [ordered]@{
            root = $mo2Root
            executable = $mo2Exe
            ini = $ini
            profilesDirectory = $profileRoot
            modsDirectory = (Join-Path $mo2Root 'mods')
            overwriteDirectory = $overwrite
            logsDirectory = (Join-Path $mo2Root 'logs')
            rootBuilderDefinitions = @($definition)
            rootBuilderDataDirectory = $rootBuilderData
            processNames = @('MO2ControlImpossibleFixtureProcess')
            gameProcessNames = @('MO2ControlImpossibleFixtureGame')
            runtimeProcessNames = @()
        }
        defaults = [ordered]@{
            profile = 'Codex'
            executable = 'Launch MGO - Do Not Unlock'
        }
        storage = [ordered]@{
            sessionStaging = $staging
            archive = $archive
        }
        limits = [ordered]@{
            maxEnumeratedFiles = 100
            overwriteWarningFiles = 10
            overwriteBlockFiles = 50
            overwriteWarningBytes = 1024
            overwriteBlockBytes = 4096
        }
        session = [ordered]@{
            lockFile = (Join-Path $sessionRoot 'active-session.lock.json')
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8

    $config = Read-MO2ControlConfig -ConfigPath $configPath
    $inspection = Invoke-MO2Inspect -Config $config
    $validation = Invoke-MO2Validate -Config $config -RequireClosed

    Assert-MO2Test ($inspection.command -eq 'inspect' -and $inspection.ok) 'clean fixture inspection succeeds'
    Assert-MO2Test ($validation.command -eq 'validate' -and $validation.ok) 'clean fixture validation succeeds'
    Assert-MO2Test ($validation.state -eq 'ready') 'clean fixture is ready'
    Assert-MO2Test ($validation.data.selectedProfile -eq 'Codex') 'ByteArray profile is decoded'
    Assert-MO2Test (@($validation.data.executables | Where-Object title -eq 'Launch MGO - Do Not Unlock').Count -eq 1) 'registered executable is parsed exactly once'
    $dialogKind = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Failed to write settings') }
    Assert-MO2Test ($dialogKind -eq 'failed-to-write-settings') 'known settings-write dialog is classified exactly'

    $missingProfile = Invoke-MO2Validate -Config $config -Profile 'Does Not Exist'
    Assert-MO2Test (-not $missingProfile.ok) 'missing exact profile blocks validation'
    Assert-MO2Test (@($missingProfile.checks | Where-Object { $_.name -eq 'requested-profile' -and $_.status -eq 'fail' }).Count -eq 1) 'profile fallback is never accepted'

    '{broken json' | Set-Content -LiteralPath $gameData -Encoding utf8
    $invalidRootBuilder = Invoke-MO2Validate -Config $config
    Assert-MO2Test (-not $invalidRootBuilder.ok) 'invalid active RootBuilder JSON blocks validation'
    Assert-MO2Test (@($invalidRootBuilder.checks | Where-Object { $_.name -eq 'rootbuilder-json' -and $_.status -eq 'fail' }).Count -eq 1) 'RootBuilder failure is attributable'

    '{}' | Set-Content -LiteralPath $gameData -Encoding utf8
    $prepareDryRun = Invoke-MO2Prepare -Config $config -Label 'fixture test' -WhatIf
    Assert-MO2Test ($prepareDryRun.ok -and $prepareDryRun.state -eq 'dry-run') 'prepare dry-run succeeds'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'prepare dry-run creates no lock'
    Assert-MO2Test (-not (Test-Path -LiteralPath $prepareDryRun.data.sessionPath -PathType Container)) 'prepare dry-run creates no evidence directory'

    $prepared = Invoke-MO2Prepare -Config $config -Label 'fixture test'
    Assert-MO2Test ($prepared.ok -and $prepared.state -eq 'prepared') 'prepare creates an owned session'
    Assert-MO2Test (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf) 'prepare creates the single-owner lock'
    Assert-MO2Test (Test-Path -LiteralPath (Join-Path $prepared.data.sessionPath 'session.json') -PathType Leaf) 'prepare creates a durable session manifest'

    $wrongSessionRejected = $false
    try { $null = Invoke-MO2Status -Config $config -SessionId 'wrong-session' } catch { $wrongSessionRejected = $true }
    Assert-MO2Test $wrongSessionRejected 'incorrect session identity is rejected'

    $sessionId = [string]$prepared.data.session.sessionId
    $status = Invoke-MO2Status -Config $config -SessionId $sessionId
    Assert-MO2Test ($status.ok -and $status.state -eq 'prepared') 'owned session status succeeds'

    $missingSession = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') open -ConfigPath $configPath -NoExit | ConvertFrom-Json)
    Assert-MO2Test (-not $missingSession.ok -and $missingSession.state -eq 'missing-session-id' -and $missingSession.data.requiredParameter -eq 'SessionId') 'entry point returns a structured missing-session precondition'

    $launchDryRun = Invoke-MO2Launch -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($launchDryRun.ok -and $launchDryRun.state -eq 'dry-run' -and $launchDryRun.data.startOnly) 'launch start-only dry-run succeeds'
    Assert-MO2Test (($launchDryRun.data.arguments -join '|') -eq '--profile|Codex|run|--executable|Launch MGO - Do Not Unlock') 'launch uses exact official MO2 profile and executable command'

    $openDryRun = Invoke-MO2Open -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($openDryRun.ok -and $openDryRun.state -eq 'dry-run' -and -not $openDryRun.data.wouldOpenGame -and $openDryRun.data.startOnly) 'open start-only dry-run opens only exact MO2'
    Assert-MO2Test (($openDryRun.data.arguments -join '|') -eq '--profile|Codex') 'open uses exact official MO2 profile command'

    $buildData = Join-Path $rootBuilderData 'BuildData.json'
    '{}' | Set-Content -LiteralPath $buildData -Encoding utf8
    $rootBuilderStatus = Invoke-MO2Status -Config $config -SessionId $sessionId
    Assert-MO2Test ($rootBuilderStatus.state -eq 'rootbuilder-recovery-required' -and $rootBuilderStatus.data.controller.activeBuildData.Count -eq 1) 'status classifies a closed stranded RootBuilder transaction'
    $rootBuilderRecovery = Invoke-MO2RecoverRootBuilder -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($rootBuilderRecovery.ok -and $rootBuilderRecovery.state -eq 'dry-run' -and $rootBuilderRecovery.data.recovery.destructiveCleanup -eq $false) 'RootBuilder recovery is an attributable exact-launch dry-run'
    Remove-Item -LiteralPath $buildData -Force

    $closeDryRun = Invoke-MO2Close -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($closeDryRun.ok -and $closeDryRun.state -eq 'dry-run' -and $closeDryRun.data.alreadyClosed) 'close dry-run is non-mutating when MO2 is already closed'
    $lockAfterCloseDryRun = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    Assert-MO2Test ($lockAfterCloseDryRun.status -eq 'prepared') 'close dry-run does not change owned session state'

    $stopDryRun = Invoke-MO2Stop -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($stopDryRun.ok -and $stopDryRun.state -eq 'dry-run' -and -not $stopDryRun.data.forceTermination) 'stop dry-run is graceful-only'

    $stopGameDryRun = Invoke-MO2StopGame -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($stopGameDryRun.ok -and $stopGameDryRun.state -eq 'dry-run' -and $stopGameDryRun.data.wouldLeaveMO2Running) 'stop-game dry-run preserves MO2 for controlled relaunch'

    $terminateDryRun = Invoke-MO2Terminate -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($terminateDryRun.ok -and $terminateDryRun.state -eq 'dry-run') 'terminate dry-run succeeds only after game/rootbuilder absence'
    Assert-MO2Test (@($terminateDryRun.errors).Count -eq 0 -and @($terminateDryRun.warnings).Count -eq 0) 'action results omit null warning and error entries'

    $releaseDryRun = Invoke-MO2Release -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($releaseDryRun.ok -and $releaseDryRun.state -eq 'dry-run') 'release dry-run succeeds'
    Assert-MO2Test (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf) 'release dry-run retains lock'
    $released = Invoke-MO2Release -Config $config -SessionId $sessionId
    Assert-MO2Test ($released.ok -and $released.state -eq 'released' -and $released.data.sessionRetained) 'release retires lock and retains evidence'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'release removes only the owned lock'

    $recoverClosed = Invoke-MO2RecoverClose -Config $config -Label 'fixture recovery' -WhatIf
    Assert-MO2Test ($recoverClosed.ok -and $recoverClosed.state -eq 'already-closed') 'recovery close is idempotent when exact MO2 is absent'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'already-closed recovery creates no lock'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

if ($IncludeLive) {
    $liveConfigPath = Join-Path $packageRoot 'config\machine.local.json'
    $liveConfig = Read-MO2ControlConfig -ConfigPath $liveConfigPath
    $live = Invoke-MO2Inspect -Config $liveConfig
    Assert-MO2Test ($live.command -eq 'inspect') 'live inspection completes'
    Assert-MO2Test ($live.data.config.mo2Root -eq $liveConfig.mo2.root) 'live inspection reports the configured MO2 root'
}

$summary = [pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    passed = $passes.Count
    failed = $failures.Count
    passes = @($passes)
    failures = @($failures)
}

$summary | ConvertTo-Json -Depth 5
if ($failures.Count -gt 0) {
    exit 1
}
