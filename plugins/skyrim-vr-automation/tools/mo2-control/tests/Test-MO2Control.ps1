# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [switch]$IncludeLive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packageRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $packageRoot 'MO2Control.psm1') -Force
$mo2Module = Get-Module MO2Control

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

$retentionFixture = & $mo2Module {
    $samples = [Collections.Generic.Queue[object]]::new()
    $samples.Enqueue([pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @([pscustomobject]@{ id = 4123 }) } })
    $samples.Enqueue([pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @() } })
    $owned = [pscustomobject]@{ data = [pscustomobject]@{ ownerPid = 4123; profile = 'Fixture'; executable = 'Fixture' } }
    $initial = $samples.Dequeue()
    $inspectionFactory = { $samples.Dequeue() }.GetNewClosure()
    Wait-MO2RetainedProcessStability -Config ([pscustomobject]@{}) -Owned $owned -InitialInspection $initial -StabilityMilliseconds 250 -PollMilliseconds 50 -InspectionFactory $inspectionFactory
}
Assert-MO2Test (-not $retentionFixture.stable -and $retentionFixture.samples.Count -eq 2 -and -not $retentionFixture.samples[-1].ownerPresent) 'MO2 retention stability detects an owner that exits immediately after game shutdown'

$lateExitDisposition = & $mo2Module {
    Get-MO2LaunchResumeDisposition -SessionStatus 'game-stopped' -GameProcesses @() -MO2Processes @() -OwnerPid 4123
}
Assert-MO2Test ($lateExitDisposition.ok -and $lateExitDisposition.mode -eq 'reopen-exact-session' -and $lateExitDisposition.reason -eq 'retained-owner-exited') 'launch reopens the exact retained session when its MO2 owner exits after stop-game'
$detectedExitDisposition = & $mo2Module {
    Get-MO2LaunchResumeDisposition -SessionStatus 'mo2-exited-after-game-stop' -GameProcesses @() -MO2Processes @() -OwnerPid 4123
}
Assert-MO2Test ($detectedExitDisposition.ok -and $detectedExitDisposition.mode -eq 'reopen-exact-session') 'launch reopens an exact session when stop-game observed its MO2 owner exit'
$retainedDisposition = & $mo2Module {
    Get-MO2LaunchResumeDisposition -SessionStatus 'game-stopped' -GameProcesses @() -MO2Processes @([pscustomobject]@{ id = 4123 }) -OwnerPid 4123 -OwnerIdentityMatched $true
}
Assert-MO2Test ($retainedDisposition.ok -and $retainedDisposition.mode -eq 'retained-owner') 'launch reuses the exact retained MO2 owner when it remains present'
$reusedPidDisposition = & $mo2Module {
    Get-MO2LaunchResumeDisposition -SessionStatus 'game-stopped' -GameProcesses @() -MO2Processes @([pscustomobject]@{ id = 4123 }) -OwnerPid 4123 -OwnerIdentityMatched $false
}
Assert-MO2Test (-not $reusedPidDisposition.ok -and $reusedPidDisposition.reason -eq 'owner-identity-mismatch') 'launch refuses a matching numeric PID when exact retained-owner identity is unproven'
$ambiguousDisposition = & $mo2Module {
    Get-MO2LaunchResumeDisposition -SessionStatus 'game-stopped' -GameProcesses @() -MO2Processes @([pscustomobject]@{ id = 9001 }) -OwnerPid 4123
}
Assert-MO2Test (-not $ambiguousDisposition.ok -and $ambiguousDisposition.reason -eq 'ambiguous-mo2-owner') 'launch refuses to adopt an unrelated MO2 process during exact-session resume'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-control-test-' + [guid]::NewGuid().ToString('N'))
try {
    $mo2Root = Join-Path $fixture 'MO2'
    $profileRoot = Join-Path $mo2Root 'profiles'
    $profile = Join-Path $profileRoot 'Codex'
    $overwrite = Join-Path $mo2Root 'overwrite'
    $rootBuilderDefinitions = Join-Path $mo2Root 'rootbuilder-definitions'
    $rootBuilderData = Join-Path $mo2Root 'rootbuilder-data'
    $gameRoot = Join-Path $fixture 'Game'
    $modsRoot = Join-Path $mo2Root 'mods'
    $loaderMod = Join-Path $modsRoot 'Skyrim Script Extender for VR (SKSEVR)'
    $ocuMod = Join-Path $modsRoot 'OpenComposite Runtime Provider'
    $unclassifiedMod = Join-Path $modsRoot 'Unknown OpenVR Runtime Provider'
    $staging = Join-Path $fixture 'staging'
    $archive = Join-Path $fixture 'archive'
    $sessionRoot = Join-Path $fixture 'sessions'

    foreach ($directory in @($profile, $overwrite, $rootBuilderDefinitions, $rootBuilderData, $gameRoot, $loaderMod, (Join-Path $ocuMod 'root'), (Join-Path $ocuMod 'SKSE\Plugins'), (Join-Path $unclassifiedMod 'root'), $staging, $archive, $sessionRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $mo2Exe = Join-Path $mo2Root 'MO2ControlFixtureProcess.exe'
    $loader = Join-Path $loaderMod 'sksevr_loader.exe'
    $plainGame = Join-Path $gameRoot 'SkyrimVR.exe'
    $fixtureGame = Join-Path $gameRoot 'MO2ControlImpossibleFixtureGame.exe'
    Copy-Item -LiteralPath $env:ComSpec -Destination $mo2Exe -Force
    Copy-Item -LiteralPath $env:ComSpec -Destination $fixtureGame -Force
    New-Item -ItemType File -Path $loader -Force | Out-Null
    New-Item -ItemType File -Path $plainGame -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'root\openvr_api.dll') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'root\opencomposite.ini') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'SKSE\Plugins\OpenCompositeInput.dll') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $unclassifiedMod 'root\openvr_api.dll') -Force | Out-Null
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8

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
2\title=@ByteArray(Skyrim VR)
2\binary=@ByteArray($plainGame)
2\arguments=@ByteArray()
2\workingDirectory=@ByteArray($gameRoot)
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
            modsDirectory = $modsRoot
            overwriteDirectory = $overwrite
            logsDirectory = (Join-Path $mo2Root 'logs')
            rootBuilderDefinitions = @($definition)
            rootBuilderDataDirectory = $rootBuilderData
            processNames = @('MO2ControlFixtureProcess')
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
    Assert-MO2Test (@($validation.data.executables | Where-Object title -eq 'Launch MGO - Do Not Unlock').capabilities -contains 'skse-loader') 'registered SKSE executable advertises its inferred capability'
    $skseRequired = Invoke-MO2Validate -Config $config -Executable 'Launch MGO - Do Not Unlock' -RequireSKSE
    Assert-MO2Test ($skseRequired.ok -and @($skseRequired.checks | Where-Object { $_.name -eq 'required-skse-loader' -and $_.status -eq 'pass' }).Count -eq 1) 'SKSE-required validation accepts the exact SKSE loader'
    $plainRejected = Invoke-MO2Validate -Config $config -Executable 'Skyrim VR' -RequireSKSE
    Assert-MO2Test (-not $plainRejected.ok -and @($plainRejected.checks | Where-Object { $_.name -eq 'required-skse-loader' -and $_.status -eq 'fail' }).Count -eq 1) 'SKSE-required validation rejects the plain game executable'
    Assert-MO2Test (@($validation.checks | Where-Object { $_.name -eq 'registered-binary-owner-mod' -and $_.status -eq 'pass' }).Count -eq 1) 'enabled executable owner mod passes validation'
    $legacySwap = Join-Path $overwrite 'ShaderCache.Swap'
    New-Item -ItemType Directory -Path $legacySwap -Force | Out-Null
    'compiled' | Set-Content -LiteralPath (Join-Path $legacySwap 'fixture.bin') -Encoding utf8
    (Get-Item -LiteralPath $legacySwap).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
    $cacheInspection = Invoke-MO2Inspect -Config $config
    $cacheValidation = Invoke-MO2Validate -Config $config -RequireClosed
    Assert-MO2Test ($cacheInspection.ok -and @($cacheInspection.data.overwrite.shaderCaches).Count -eq 1) 'inspection inventories forbidden overwrite ShaderCache trees'
    Assert-MO2Test ($cacheInspection.data.overwrite.shaderCaches[0].role -eq 'temporary-swap' -and $cacheInspection.data.overwrite.shaderCaches[0].stale) 'inspection classifies a persistent ShaderCache.Swap tree as stale temporary state'
    Assert-MO2Test (-not $cacheValidation.ok -and @($cacheValidation.checks | Where-Object { $_.name -eq 'overwrite' -and $_.status -eq 'fail' }).Count -eq 1) 'validation blocks launch while a ShaderCache tree remains in overwrite'
    Remove-Item -LiteralPath $legacySwap -Recurse -Force
    @('-Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $disabledOwner = Invoke-MO2Validate -Config $config -RequireClosed
    Assert-MO2Test (-not $disabledOwner.ok) 'disabled executable owner mod blocks validation'
    Assert-MO2Test (@($disabledOwner.checks | Where-Object { $_.name -eq 'registered-binary-owner-mod' -and $_.status -eq 'fail' }).Count -eq 1) 'disabled owner failure is attributable'
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $dialogKind = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Failed to write settings') }
    Assert-MO2Test ($dialogKind -eq 'failed-to-write-settings') 'known settings-write dialog is classified exactly'
    $unlockDialogKind = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'vrserver.exe' -Buttons @([pscustomobject]@{name='Unlock'}) }
    Assert-MO2Test ($unlockDialogKind -eq 'unlock-required') 'Unlock dialog is classified structurally even when titled with a child executable'
    $failedRunDialogKind = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Failed to run SkyrimVR.exe') -Buttons @([pscustomobject]@{name='OK'}) }
    Assert-MO2Test ($failedRunDialogKind -eq 'failed-to-run') 'retained failed-to-run dialog is classified without matching the main window'
    $preparingVfsKind = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Preparing vfs') -Buttons @([pscustomobject]@{name='Cancel'}) }
    Assert-MO2Test ($preparingVfsKind -eq 'preparing-vfs') 'Preparing vfs is classified only with one exact Cancel control'
    $preparingVfsWithoutCancel = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Preparing vfs') -Buttons @() }
    Assert-MO2Test ($null -eq $preparingVfsWithoutCancel) 'Preparing vfs text without an exact Cancel control is not actioned'
    $cancelWithoutPreparingVfs = & (Get-Module MO2Control) { Get-MO2KnownDialogKind -Title 'Mod Organizer' -Texts @('Ready') -Buttons @([pscustomobject]@{name='Cancel'}) }
    Assert-MO2Test ($null -eq $cancelWithoutPreparingVfs) 'an unrelated Cancel control is not classified as a VFS stall'
    $transientWindow = [pscustomobject]@{ callCount = 0 }
    $transientWindow | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param($scope, $condition)
        $this.callCount++
        if ($this.callCount -eq 1) { throw [InvalidOperationException]::new('Unrecognized error') }
        return @('recovered')
    }
    $uiaRecovered = & $mo2Module { param($window) Invoke-MO2UiAutomationFindAll -Window $window -Scope 'fixture-scope' -Condition 'fixture-condition' -RetryDelayMilliseconds 0 } $transientWindow
    Assert-MO2Test ($transientWindow.callCount -eq 2 -and @($uiaRecovered).Count -eq 1 -and @($uiaRecovered)[0] -eq 'recovered') 'transient UI Automation enumeration is retried once within a bounded operation'

    $openingOwned = [pscustomobject]@{ data = [pscustomobject]@{ status = 'opening' } }
    $openingResolution = [pscustomobject]@{ ok = $true; targets = @([pscustomobject]@{ id = 101 }) }
    $openingReady = & $mo2Module { param($owned, $resolution) Test-MO2OpeningReady -Owned $owned -OwnershipResolution $resolution -MO2Processes @([pscustomobject]@{ id = 101 }) -GameProcesses @() -Windows @([pscustomobject]@{ visible = $true; automationId = 'MainWindow' }) } $openingOwned $openingResolution
    Assert-MO2Test $openingReady 'an exact adopted StartOnly MO2 main window is eligible for durable mo2-open promotion'

    $completionSupersession = & $mo2Module {
        param($cfg, $gameRecord)
        $originalOwnedSession = (Get-Command Get-MO2OwnedSession -CommandType Function).ScriptBlock
        $initiating = [pscustomobject]@{ sessionId='supersession-session'; data=[pscustomobject]@{ generation=4L; status='launching' } }
        $current = [pscustomobject]@{ sessionId='supersession-session'; data=[pscustomobject]@{
            generation=5L; status='running'; launchAttemptId='launch-attempt'; gameProcessesLaunchAttemptId='launch-attempt'; gameProcesses=@($gameRecord)
            ownerTransition=[pscustomobject]@{ kind='launch'; attemptId='launch-attempt' }
        } }
        try {
            Set-Item Function:script:Get-MO2OwnedSession -Value ({ $current }.GetNewClosure())
            $launch = Get-MO2SynchronousCompletionSupersession -Config $cfg -Owned $initiating -SessionId 'supersession-session' -Operation launch -AttemptId 'launch-attempt'
            $launchResult = New-MO2SynchronousCompletionSupersededResult -Config $cfg -Supersession $launch -SessionId 'supersession-session'
            $current.data.status = 'mo2-closed'
            $current.data.ownerTransition = [pscustomobject]@{ kind='open'; attemptId='open-attempt' }
            $open = Get-MO2SynchronousCompletionSupersession -Config $cfg -Owned $initiating -SessionId 'supersession-session' -Operation open -AttemptId 'open-attempt'
            $openResult = New-MO2SynchronousCompletionSupersededResult -Config $cfg -Supersession $open -SessionId 'supersession-session'
            [pscustomobject]@{ launch=$launch; launchResult=$launchResult; open=$open; openResult=$openResult; finalStatus=[string]$current.data.status; finalGeneration=[long]$current.data.generation }
        }
        finally { Set-Item Function:script:Get-MO2OwnedSession -Value $originalOwnedSession }
    } $config ([pscustomobject]@{ id=202; name='MO2ControlImpossibleFixtureGame' })
    Assert-MO2Test ($completionSupersession.launch.superseded -and $completionSupersession.launch.equivalentSuccess -and
        $completionSupersession.launchResult.ok -and $completionSupersession.launchResult.state -eq 'game-running' -and
        $completionSupersession.launchResult.data.completionSuperseded) 'a synchronous launch overtaken by status adoption recognizes only the same exact completed launch without rewriting it'
    Assert-MO2Test ($completionSupersession.open.superseded -and -not $completionSupersession.open.equivalentSuccess -and
        -not $completionSupersession.openResult.ok -and $completionSupersession.openResult.state -eq 'open-superseded' -and
        $completionSupersession.finalStatus -eq 'mo2-closed' -and $completionSupersession.finalGeneration -eq 5L) 'a synchronous open overtaken by a newer lifecycle reports supersession and preserves the newer generation'

    $publicLaunchInterleaving = & $mo2Module {
        param($cfg, $ownerPath, $gamePath)
        $functionNames = @('Get-MO2OwnedSession','Invoke-MO2Validate','Get-MO2ProcessRecords','Get-MO2DispatchBoundChildEvidence','Write-MO2JsonAtomic','Invoke-MO2OwnedSessionMutation','Get-MO2InspectionData','Get-MO2WindowSnapshot','Resolve-MO2OwnedProcessTarget','Get-MO2ObservedGameProcessAdoption')
        if (Get-Command Get-MO2TaskWorkspaceIsolation -CommandType Function -ErrorAction SilentlyContinue) { $functionNames += 'Get-MO2TaskWorkspaceIsolation' }
        $originals = @{}
        foreach ($name in $functionNames) { $originals[$name] = (Get-Command $name -CommandType Function).ScriptBlock }
        $ownerStart = [DateTimeOffset]::UtcNow.AddSeconds(-2).ToString('o')
        $gameStart = [DateTimeOffset]::UtcNow.ToString('o')
        $ownerRecord = [pscustomobject]@{ id=501; name='MO2ControlFixtureProcess'; path=$ownerPath; startTime=$ownerStart }
        $gameRecord = [pscustomobject]@{ id=502; name='MO2ControlImpossibleFixtureGame'; path=$gamePath; startTime=$gameStart }
        $script:PublicLaunchGetCalls = 0
        $script:PublicLaunchMutationCalls = 0
        $script:PublicLaunchInitial = [pscustomobject]@{ path='fixture-lock'; sessionId='public-launch'; accessId='access'; data=[pscustomobject]@{ generation=0L; accessId='access'; status='prepared'; profile='Codex'; executable='Launch MGO - Do Not Unlock'; sessionPath='fixture-session'; requirements=[pscustomobject]@{ skseLoader=$false }; gameProcesses=@([pscustomobject]@{ id=400 }) } }
        $script:PublicLaunchCurrent = $null
        try {
            Set-Item Function:script:Get-MO2OwnedSession { $script:PublicLaunchGetCalls++; if ($script:PublicLaunchGetCalls -eq 1) { $script:PublicLaunchInitial } else { $script:PublicLaunchCurrent } }
            Set-Item Function:script:Invoke-MO2Validate { [pscustomobject]@{ ok=$true; warnings=@(); errors=@(); data=[pscustomobject]@{ config=[pscustomobject]@{ mo2Executable=$ownerPath }; processes=[pscustomobject]@{ mo2=@(); game=@() }; sessionLock=[pscustomobject]@{ ownerIdentityMatched=$false } } } }
            if ($functionNames -contains 'Get-MO2TaskWorkspaceIsolation') { Set-Item Function:script:Get-MO2TaskWorkspaceIsolation { [pscustomobject]@{ ok=$true; errors=@() } } }
            Set-Item Function:script:Get-MO2ProcessRecords { @($ownerRecord) }
            Set-Item Function:script:Get-MO2DispatchBoundChildEvidence { @() }
            Set-Item Function:script:Write-MO2JsonAtomic { }
            Set-Item Function:script:Invoke-MO2OwnedSessionMutation {
                param($Owned, $Action)
                $script:PublicLaunchMutationCalls++
                if ($script:PublicLaunchMutationCalls -eq 1) {
                    $outcome = & $Action $Owned.data
                    $outcome.sessionData | Add-Member -NotePropertyName generation -NotePropertyValue 1L -Force
                    $Owned.data = $outcome.sessionData
                    return $outcome.result
                }
                $newer = $Owned.data | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                $newer.generation = 2L
                $newer.status = 'running'
                $newer | Add-Member -NotePropertyName gameProcesses -NotePropertyValue @($gameRecord) -Force
                $newer | Add-Member -NotePropertyName gameProcessesLaunchAttemptId -NotePropertyValue ([string]$newer.launchAttemptId) -Force
                $script:PublicLaunchCurrent = [pscustomobject]@{ path=$Owned.path; sessionId=$Owned.sessionId; accessId=$Owned.accessId; data=$newer }
                throw "Session '$($Owned.sessionId)' lease transition is stale: expected generation 1, current generation 2."
            }
            Set-Item Function:script:Get-MO2InspectionData { [pscustomobject]@{ processes=[pscustomobject]@{ mo2=@($ownerRecord); game=@($gameRecord) } } }
            Set-Item Function:script:Get-MO2WindowSnapshot { @() }
            Set-Item Function:script:Resolve-MO2OwnedProcessTarget { [pscustomobject]@{ ok=$true; adopted=$false; ownerPid=501; targets=@($ownerRecord); reason='recorded-owner' } }
            Set-Item Function:script:Get-MO2ObservedGameProcessAdoption { [pscustomobject]@{ eligible=$true; records=@($gameRecord); reasons=@() } }
            Set-Item Function:script:Start-Process { [pscustomobject]@{ Id=501; ProcessName='MO2ControlFixtureProcess'; StartTime=[DateTime]::UtcNow.AddSeconds(-2); HasExited=$false; ExitCode=$null } }
            Set-Item Function:script:Start-Sleep { }
            $result = Invoke-MO2Launch -Config $cfg -SessionId 'public-launch' -TimeoutSeconds 1
            [pscustomobject]@{ result=$result; mutationCalls=$script:PublicLaunchMutationCalls; status=[string]$script:PublicLaunchCurrent.data.status; generation=[long]$script:PublicLaunchCurrent.data.generation }
        }
        finally {
            foreach ($name in $functionNames) { Set-Item "Function:script:$name" -Value $originals[$name] }
            Remove-Item Function:script:Start-Process, Function:script:Start-Sleep -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name PublicLaunchGetCalls,PublicLaunchMutationCalls,PublicLaunchInitial,PublicLaunchCurrent -ErrorAction SilentlyContinue
        }
    } $config $mo2Exe $fixtureGame
    Assert-MO2Test ($publicLaunchInterleaving.result.ok -and $publicLaunchInterleaving.result.state -eq 'game-running' -and
        $publicLaunchInterleaving.result.data.completionSuperseded -and $publicLaunchInterleaving.mutationCalls -eq 2 -and
        $publicLaunchInterleaving.status -eq 'running' -and $publicLaunchInterleaving.generation -eq 2L) 'public synchronous launch preserves a concurrent same-attempt status adoption instead of writing launch-failed'

    $publicOpenInterleaving = & $mo2Module {
        param($cfg, $ownerPath)
        $functionNames = @('Get-MO2OwnedSession','Test-MO2InteractiveDesktop','Invoke-MO2Validate','Get-MO2ProcessRecords','Get-MO2DispatchBoundChildEvidence','Write-MO2JsonAtomic','Invoke-MO2OwnedSessionMutation','Resolve-MO2OwnedProcessTarget','Get-MO2WindowSnapshot','Write-MO2OwnedSessionAtomic')
        if (Get-Command Get-MO2TaskWorkspaceIsolation -CommandType Function -ErrorAction SilentlyContinue) { $functionNames += 'Get-MO2TaskWorkspaceIsolation' }
        $originals = @{}
        foreach ($name in $functionNames) { $originals[$name] = (Get-Command $name -CommandType Function).ScriptBlock }
        $ownerStart = [DateTimeOffset]::UtcNow.AddSeconds(-2).ToString('o')
        $ownerRecord = [pscustomobject]@{ id=601; name='MO2ControlFixtureProcess'; path=$ownerPath; startTime=$ownerStart }
        $script:PublicOpenGetCalls = 0
        $script:PublicOpenMutationCalls = 0
        $script:PublicOpenInitial = [pscustomobject]@{ path='fixture-lock'; sessionId='public-open'; accessId='access'; data=[pscustomobject]@{ generation=0L; accessId='access'; status='prepared'; profile='Codex'; executable='Launch MGO - Do Not Unlock'; sessionPath='fixture-session' } }
        $script:PublicOpenCurrent = $null
        try {
            Set-Item Function:script:Get-MO2OwnedSession { $script:PublicOpenGetCalls++; if ($script:PublicOpenGetCalls -eq 1) { $script:PublicOpenInitial } else { $script:PublicOpenCurrent } }
            Set-Item Function:script:Test-MO2InteractiveDesktop { $true }
            Set-Item Function:script:Invoke-MO2Validate { [pscustomobject]@{ ok=$true; warnings=@(); errors=@(); data=[pscustomobject]@{ config=[pscustomobject]@{ mo2Executable=$ownerPath } } } }
            if ($functionNames -contains 'Get-MO2TaskWorkspaceIsolation') { Set-Item Function:script:Get-MO2TaskWorkspaceIsolation { [pscustomobject]@{ ok=$true; errors=@() } } }
            Set-Item Function:script:Get-MO2ProcessRecords { @($ownerRecord) }
            Set-Item Function:script:Get-MO2DispatchBoundChildEvidence { @() }
            Set-Item Function:script:Write-MO2JsonAtomic { }
            Set-Item Function:script:Invoke-MO2OwnedSessionMutation {
                param($Owned, $Action)
                $script:PublicOpenMutationCalls++
                $outcome = & $Action $Owned.data
                $outcome.sessionData | Add-Member -NotePropertyName generation -NotePropertyValue 1L -Force
                $Owned.data = $outcome.sessionData
                return $outcome.result
            }
            Set-Item Function:script:Resolve-MO2OwnedProcessTarget { [pscustomobject]@{ ok=$true; adopted=$false; ownerPid=601; targets=@($ownerRecord); reason='recorded-owner' } }
            Set-Item Function:script:Get-MO2WindowSnapshot { @([pscustomobject]@{ visible=$true; automationAvailable=$true; automationId='MainWindow' }) }
            Set-Item Function:script:Write-MO2OwnedSessionAtomic {
                param($Owned, $Value)
                $newer = $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                $newer.generation = 2L
                $newer.status = 'mo2-closed'
                $script:PublicOpenCurrent = [pscustomobject]@{ path=$Owned.path; sessionId=$Owned.sessionId; accessId=$Owned.accessId; data=$newer }
                throw "Session '$($Owned.sessionId)' lease transition is stale: expected generation 1, current generation 2."
            }
            Set-Item Function:script:Start-Process { [pscustomobject]@{ Id=601; ProcessName='MO2ControlFixtureProcess'; StartTime=[DateTime]::UtcNow.AddSeconds(-2); HasExited=$false; ExitCode=$null } }
            Set-Item Function:script:Start-Sleep { }
            $result = Invoke-MO2Open -Config $cfg -SessionId 'public-open' -TimeoutSeconds 1
            [pscustomobject]@{ result=$result; mutationCalls=$script:PublicOpenMutationCalls; status=[string]$script:PublicOpenCurrent.data.status; generation=[long]$script:PublicOpenCurrent.data.generation }
        }
        finally {
            foreach ($name in $functionNames) { Set-Item "Function:script:$name" -Value $originals[$name] }
            Remove-Item Function:script:Start-Process, Function:script:Start-Sleep -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name PublicOpenGetCalls,PublicOpenMutationCalls,PublicOpenInitial,PublicOpenCurrent -ErrorAction SilentlyContinue
        }
    } $config $mo2Exe
    Assert-MO2Test (-not $publicOpenInterleaving.result.ok -and $publicOpenInterleaving.result.state -eq 'open-superseded' -and
        $publicOpenInterleaving.result.data.completionSuperseded -and $publicOpenInterleaving.mutationCalls -eq 1 -and
        $publicOpenInterleaving.status -eq 'mo2-closed' -and $publicOpenInterleaving.generation -eq 2L) 'public synchronous open preserves a concurrent newer closed lifecycle instead of rewriting mo2-open'

    $launchUtc = [DateTimeOffset]::UtcNow.AddSeconds(-1)
    $ownerStartUtc = [DateTimeOffset]::UtcNow.AddSeconds(-2)
    $launchingOwned = [pscustomobject]@{ data = [pscustomobject]@{ status = 'launching'; executable = 'Launch MGO - Do Not Unlock'; launchedUtc = $launchUtc.ToString('o'); launchDispatchedUtc = $launchUtc.ToString('o'); launchAttemptId = 'launch-1'; preLaunchGameProcesses = @(); ownerPid = 101; processPath = $mo2Exe; processStartTime = $ownerStartUtc.ToString('o'); gameProcesses = @() } }
    $launchOwner = [pscustomobject]@{ ok = $true; ownerPid = 101; targets = @([pscustomobject]@{ id = 101; name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $ownerStartUtc.ToString('o') }) }
    $observedGame = [pscustomobject]@{ id = 202; name = 'MO2ControlImpossibleFixtureGame'; path = $fixtureGame; startTime = [DateTimeOffset]::UtcNow.UtcDateTime.ToString('o') }
    $gameAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $launchOwner @($observedGame)
    Assert-MO2Test ($gameAdoption.eligible -and $gameAdoption.records.Count -eq 1 -and $gameAdoption.records[0].id -eq 202 -and $gameAdoption.records[0].path -eq $fixtureGame) 'StartOnly status can adopt one exact configured post-launch game identity under a freshly proven MO2 owner'
    $stagedConfig = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $stagedConfig.mo2.gameProcessNames = @('MO2ControlImpossibleFixtureGame', 'MO2ControlImpossibleFixtureLoader')
    $fixtureLoader = Join-Path $gameRoot 'MO2ControlImpossibleFixtureLoader.exe'
    New-Item -ItemType File -Path $fixtureLoader -Force | Out-Null
    $observedLoader = [pscustomobject]@{ id = 212; name = 'MO2ControlImpossibleFixtureLoader'; path = $fixtureLoader; startTime = [DateTimeOffset]::UtcNow.UtcDateTime.ToString('o') }
    $loaderOnlyAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $stagedConfig $launchingOwned $launchOwner @($observedLoader)
    $loaderThenGameAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $stagedConfig $launchingOwned $launchOwner @($observedLoader, $observedGame)
    $gameOnlyAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $stagedConfig $launchingOwned $launchOwner @($observedGame)
    Assert-MO2Test (-not $loaderOnlyAdoption.eligible -and $loaderOnlyAdoption.reasons -contains 'primary-game-not-observed') 'a loader-only observation remains pending instead of permanently closing the launch identity set'
    Assert-MO2Test ($loaderThenGameAdoption.eligible -and @($loaderThenGameAdoption.records).Count -eq 2 -and $gameOnlyAdoption.eligible) 'the same launch can adopt the primary game with or without its configured loader once the primary role appears'
    $predatingGame = [pscustomobject]@{ id = 203; name = 'MO2ControlImpossibleFixtureGame'; path = $fixtureGame; startTime = $launchUtc.AddMilliseconds(-1).ToString('o') }
    $predatingAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $launchOwner @($predatingGame)
    Assert-MO2Test (-not $predatingAdoption.eligible -and $predatingAdoption.reasons -contains 'game-predates-launch:203') 'status refuses to assign a pre-existing game process to a StartOnly launch'
    $wrongPathGame = [pscustomobject]@{ id = 204; name = 'MO2ControlImpossibleFixtureGame'; path = (Join-Path $fixture 'wrong\MO2ControlImpossibleFixtureGame.exe'); startTime = [DateTimeOffset]::UtcNow.ToString('o') }
    $wrongPathAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $launchOwner @($wrongPathGame)
    Assert-MO2Test (-not $wrongPathAdoption.eligible -and $wrongPathAdoption.reasons -contains 'unconfigured-game-identity:204') 'StartOnly adoption rejects a configured basename from the wrong executable directory'
    $duplicateRoleGame = [pscustomobject]@{ id = 205; name = $observedGame.name; path = $observedGame.path; startTime = $observedGame.startTime }
    $ambiguousGameAdoption = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $launchOwner @($observedGame, $duplicateRoleGame)
    Assert-MO2Test (-not $ambiguousGameAdoption.eligible -and $ambiguousGameAdoption.reasons -contains 'ambiguous-game-role:MO2ControlImpossibleFixtureGame') 'StartOnly adoption rejects two distinct candidates for one configured game role'
    $extraOwner = [pscustomobject]@{ id = 102; name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $ownerStartUtc.AddSeconds(1).ToString('o') }
    $extraOwnerAdoption = & $mo2Module { param($cfg, $owned, $owner, $extra, $processes) $factory = { @($owner.targets[0], $extra) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $launchOwner $extraOwner @($observedGame)
    Assert-MO2Test (-not $extraOwnerAdoption.eligible -and $extraOwnerAdoption.reasons -contains 'mo2-owner-not-exact') 'StartOnly adoption rejects the recorded owner when an additional MO2 process makes attribution ambiguous'
    $transitionSession = Join-Path $fixture 'transition-session'
    New-Item -ItemType Directory -Path $transitionSession -Force | Out-Null
    $transitionReceiptPath = Join-Path $transitionSession 'mo2-launch-started.json'
    $transitionDispatch = [DateTimeOffset]::UtcNow.AddSeconds(-2)
    $transitionRequestedStart = $transitionDispatch.AddMilliseconds(100)
    $transitionAttemptId = [guid]::NewGuid().ToString('D')
    [pscustomobject][ordered]@{ sessionId = 'transition-session'; attemptId = $transitionAttemptId; requestedPid = 777; requestedProcessStartTime = $transitionRequestedStart.ToString('o'); mo2Path = $mo2Exe; dispatchStartedUtc = $transitionDispatch.ToString('o'); preDispatchProcesses = @() } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $transitionReceiptPath -Encoding utf8
    $transitionOwned = [pscustomobject]@{ sessionId = 'transition-session'; data = [pscustomobject]@{ sessionId = 'transition-session'; sessionPath = $transitionSession; status = 'launching'; ownerPid = 777; processPath = $mo2Exe; processStartTime = $transitionRequestedStart.ToString('o'); ownerTransition = [pscustomobject]@{ kind = 'launch'; attemptId = $transitionAttemptId; dispatchStartedUtc = $transitionDispatch.ToString('o'); requestedPid = 777; requestedProcessPath = $mo2Exe; requestedProcessStartTime = $transitionRequestedStart.ToString('o'); preDispatchProcesses = @(); receiptPath = $transitionReceiptPath; detachedAdoptionAllowed = $true } } }
    $unrelatedOwner = [pscustomobject]@{ id = 778; parentId = 123; name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $transitionDispatch.AddSeconds(1).ToString('o') }
    $handoffOwner = [pscustomobject]@{ id = 778; parentId = 777; parentStartTime = $transitionRequestedStart.ToString('o'); name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $transitionDispatch.AddSeconds(1).ToString('o') }
    $unrelatedOwnerResolution = & $mo2Module { param($cfg, $owned, $process) Resolve-MO2OwnedProcessTarget -Config $cfg -Owned $owned -Processes @($process) -AdoptDetachedOwner } $config $transitionOwned $unrelatedOwner
    $handoffEvidence = & $mo2Module { param($cfg, $owned, $process) Test-MO2DetachedOwnerAdoptionEvidence -Config $cfg -Owned $owned -Candidate $process } $config $transitionOwned $handoffOwner
    $legacyTransitionOwned = $transitionOwned | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $legacyTransitionOwned.data.PSObject.Properties.Remove('ownerTransition')
    $legacyEvidence = & $mo2Module { param($cfg, $owned, $process) Test-MO2DetachedOwnerAdoptionEvidence -Config $cfg -Owned $owned -Candidate $process } $config $legacyTransitionOwned $handoffOwner
    $unboundTransitionOwned = $transitionOwned | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unboundTransitionOwned.data.PSObject.Properties.Remove('processStartTime')
    $unboundEvidence = & $mo2Module { param($cfg, $owned, $process) Test-MO2DetachedOwnerAdoptionEvidence -Config $cfg -Owned $owned -Candidate $process } $config $unboundTransitionOwned $handoffOwner
    $reusedParentOwner = $handoffOwner | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $reusedParentOwner.parentStartTime = $transitionRequestedStart.AddMinutes(1).ToString('o')
    $reusedParentEvidence = & $mo2Module { param($cfg, $owned, $process) Test-MO2DetachedOwnerAdoptionEvidence -Config $cfg -Owned $owned -Candidate $process } $config $transitionOwned $reusedParentOwner
    $postExitHandoffOwner = [pscustomobject]@{ id=778; parentId=777; name='MO2ControlFixtureProcess'; path=$mo2Exe; startTime=$transitionDispatch.AddSeconds(1).ToString('o') }
    $durableChild = [pscustomobject]@{ id=778; parentId=777; parentStartTime=$transitionRequestedStart.ToString('o'); name='MO2ControlFixtureProcess'; path=$mo2Exe; startTime=$transitionDispatch.AddSeconds(1).ToString('o') }
    $transitionOwned.data.ownerTransition | Add-Member -NotePropertyName dispatchBoundChildren -NotePropertyValue @($durableChild) -Force
    $transitionReceipt = Get-Content -LiteralPath $transitionReceiptPath -Raw | ConvertFrom-Json
    $transitionReceipt | Add-Member -NotePropertyName dispatchBoundChildren -NotePropertyValue @($durableChild) -Force
    $transitionReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $transitionReceiptPath -Encoding utf8
    $postExitHandoffEvidence = & $mo2Module { param($cfg, $owned, $process) Test-MO2DetachedOwnerAdoptionEvidence -Config $cfg -Owned $owned -Candidate $process } $config $transitionOwned $postExitHandoffOwner
    Assert-MO2Test (-not $unrelatedOwnerResolution.ok -and $unrelatedOwnerResolution.reason -eq 'detached-owner-handoff-unproven') 'an unrelated later configured MO2 process cannot replace launch-recorded ownership'
    Assert-MO2Test ($handoffEvidence.ok -and $handoffEvidence.reason -eq 'dispatch-bound-detached-owner') 'a direct requested-process handoff remains eligible under matching durable dispatch evidence'
    Assert-MO2Test (-not $legacyEvidence.ok -and $legacyEvidence.reason -eq 'detached-owner-transition-unavailable') 'legacy or missing transition fields remain readable but cannot manufacture live owner authority'
    Assert-MO2Test (-not $unboundEvidence.ok -and $unboundEvidence.reason -eq 'detached-owner-original-identity-unbound') 'detached adoption refuses a missing original owner tuple instead of replacing it with the candidate identity'
    Assert-MO2Test (-not $reusedParentEvidence.ok -and $reusedParentEvidence.reason -eq 'detached-owner-handoff-unproven') 'a matching parent PID from a different process lifetime cannot authorize detached adoption'
    Assert-MO2Test ($postExitHandoffEvidence.ok -and $postExitHandoffEvidence.reason -eq 'dispatch-bound-detached-owner') 'a direct child captured while the original helper handle was retained remains adoptable after that parent exits'
    $reusedOwnerRecord = [pscustomobject]@{ id = 101; name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $ownerStartUtc.AddMinutes(1).ToString('o') }
    $reusedOwnerResolution = & $mo2Module { param($cfg, $owned, $process) Resolve-MO2OwnedProcessTarget -Config $cfg -Owned $owned -Processes @($process) } $config $launchingOwned $reusedOwnerRecord
    $reusedOwnerAdoption = & $mo2Module { param($cfg, $owned, $process, $processes) $factory = { @($process) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $launchingOwned $reusedOwnerRecord @($observedGame)
    Assert-MO2Test (-not $reusedOwnerResolution.ok -and $reusedOwnerResolution.reason -eq 'recorded-owner-start-time-mismatch') 'recorded MO2 ownership rejects a reused PID with a different process start time'
    Assert-MO2Test (-not $reusedOwnerAdoption.eligible -and $reusedOwnerAdoption.reasons -contains 'mo2-owner-not-exact') 'StartOnly status cannot adopt game identities under a stale or replaced MO2 owner snapshot'
    $unlockCalls = [Collections.Generic.List[int]]::new()
    $activeBuildDataInspection = [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @($reusedOwnerRecord); game = @() }; rootBuilder = [pscustomobject]@{ active = @([pscustomobject]@{ path = (Join-Path $fixture 'BuildData.json') }) } }
    $replacementInspectionFactory = { $activeBuildDataInspection }.GetNewClosure()
    $unlockCallback = { param($process) $unlockCalls.Add([int]$process.id); return $true }.GetNewClosure()
    $replacementUnlock = & $mo2Module { param($cfg, $owned, $factory, $action) Invoke-MO2UnlockOnly -Config $cfg -Owned $owned -TimeoutSeconds 1 -PollMilliseconds 0 -InspectionFactory $factory -UnlockAction $action } $config $launchingOwned $replacementInspectionFactory $unlockCallback
    Assert-MO2Test (-not $replacementUnlock.restored -and -not $replacementUnlock.ownerIdentityVerified -and $replacementUnlock.blockedReason -eq 'recorded-owner-start-time-mismatch' -and $unlockCalls.Count -eq 0) 'RootBuilder Unlock refuses a reused MO2 owner identity before invoking any UI action'
    $testUnlockBindingFactory = { param([int]$processId) [pscustomobject]@{ available=$true; reason='bound'; process=[pscustomobject]@{ Id=$processId } } }
    $exactUnlockIdentityFactory = { param($binding) $launchOwner.targets[0] }.GetNewClosure()
    $exactUnlockState = [pscustomobject]@{ calls = 0 }
    $exactUnlockFactory = { $exactUnlockState.calls++; [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @($launchOwner.targets[0]); game = @() }; rootBuilder = [pscustomobject]@{ active = $(if ($exactUnlockState.calls -eq 1) { @([pscustomobject]@{ path = (Join-Path $fixture 'BuildData.json') }) } else { @() }) } } }.GetNewClosure()
    $exactUnlock = & $mo2Module { param($cfg, $owned, $factory, $action, $bindingFactory, $identityFactory) Invoke-MO2UnlockOnly -Config $cfg -Owned $owned -TimeoutSeconds 1 -PollMilliseconds 0 -InspectionFactory $factory -UnlockAction $action -BindingFactory $bindingFactory -OwnerIdentityFactory $identityFactory } $config $launchingOwned $exactUnlockFactory $unlockCallback $testUnlockBindingFactory $exactUnlockIdentityFactory
    Assert-MO2Test ($exactUnlock.restored -and $exactUnlock.ownerIdentityVerified -and $unlockCalls.Count -eq 1) 'RootBuilder Unlock acts only on the exact current owner and revalidates it for final success'
    $actionBoundaryIdentityState = [pscustomobject]@{ calls = 0 }
    $replacementAtActionIdentityFactory = { param($binding) $actionBoundaryIdentityState.calls++; if ($actionBoundaryIdentityState.calls -eq 1) { $launchOwner.targets[0] } else { $reusedOwnerRecord } }.GetNewClosure()
    $replacementAtActionInspection = { [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @($launchOwner.targets[0]); game = @() }; rootBuilder = [pscustomobject]@{ active = @([pscustomobject]@{ path = (Join-Path $fixture 'BuildData.json') }) } } }.GetNewClosure()
    $callsBeforeActionBoundaryTest = $unlockCalls.Count
    $replacementAtAction = & $mo2Module { param($cfg, $owned, $factory, $action, $bindingFactory, $identityFactory) Invoke-MO2UnlockOnly -Config $cfg -Owned $owned -TimeoutSeconds 1 -PollMilliseconds 0 -InspectionFactory $factory -UnlockAction $action -BindingFactory $bindingFactory -OwnerIdentityFactory $identityFactory } $config $launchingOwned $replacementAtActionInspection $unlockCallback $testUnlockBindingFactory $replacementAtActionIdentityFactory
    Assert-MO2Test (-not $replacementAtAction.restored -and $replacementAtAction.blockedReason -eq 'recorded-owner-start-time-mismatch' -and $unlockCalls.Count -eq $callsBeforeActionBoundaryTest) 'RootBuilder Unlock revalidates the retained exact owner after window selection and immediately before invoking Unlock'
    $betweenControlsIdentityState = [pscustomobject]@{ calls = 0 }
    $betweenControlsIdentityFactory = { param($binding) $betweenControlsIdentityState.calls++; if ($betweenControlsIdentityState.calls -le 2) { $launchOwner.targets[0] } else { $reusedOwnerRecord } }.GetNewClosure()
    $twoUnlockControls = { param($binding) @([pscustomobject]@{ windowTitle='first'; button='first' }, [pscustomobject]@{ windowTitle='second'; button='second' }) }
    $controlActions = [Collections.Generic.List[string]]::new()
    $controlAction = { param($control) $controlActions.Add([string]$control.button); $true }.GetNewClosure()
    $replacementBetweenControls = & $mo2Module { param($cfg, $owned, $factory, $bindingFactory, $identityFactory, $controlFactory, $controlAction) Invoke-MO2UnlockOnly -Config $cfg -Owned $owned -TimeoutSeconds 1 -PollMilliseconds 0 -InspectionFactory $factory -BindingFactory $bindingFactory -OwnerIdentityFactory $identityFactory -UnlockControlFactory $controlFactory -UnlockControlAction $controlAction } $config $launchingOwned $replacementAtActionInspection $testUnlockBindingFactory $betweenControlsIdentityFactory $twoUnlockControls $controlAction
    Assert-MO2Test (-not $replacementBetweenControls.restored -and $replacementBetweenControls.blockedReason -eq 'recorded-owner-start-time-mismatch' -and @($controlActions).Count -eq 1 -and $controlActions[0] -eq 'first') 'RootBuilder Unlock revalidates the retained owner between multiple eligible Unlock controls and stops before acting on a replacement lifetime'
    $replacementCloseInventory = { param($fixtureConfig) @($reusedOwnerRecord) }.GetNewClosure()
    $replacementClose = & $mo2Module { param($cfg, $owned, $initial, $factory) Invoke-MO2CooperativeCloseCore -Config $cfg -Owned $owned -InitialProcesses @($initial) -TimeoutSeconds 1 -ProcessInventoryFactory $factory } $config $launchingOwned $launchOwner.targets[0] $replacementCloseInventory
    Assert-MO2Test (-not $replacementClose.closed -and -not $replacementClose.ownerIdentityVerified -and $replacementClose.blockedReason -eq 'recorded-owner-start-time-mismatch' -and @($replacementClose.actions).Count -eq 0) 'cooperative close refuses a reused MO2 owner identity before invoking any UI action'
    $preLaunchOwned = $launchingOwned | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $preLaunchOwned.data.processStartTime = $ownerStartUtc.ToString('o')
    $preLaunchOwned.data.preLaunchGameProcesses = @($observedGame)
    $presentBeforeDispatch = & $mo2Module { param($cfg, $owned, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned $owned -Processes $processes -OwnerProcessInventoryFactory $factory } $config $preLaunchOwned $launchOwner @($observedGame)
    Assert-MO2Test (-not $presentBeforeDispatch.eligible -and $presentBeforeDispatch.reasons -contains 'game-present-before-dispatch:202') 'StartOnly adoption rejects an exact game identity captured before dispatch'
    $relaunchState = [pscustomobject]@{ status = 'launching'; executable = 'Launch MGO - Do Not Unlock'; ownerPid = 101; processPath = $mo2Exe; processStartTime = $ownerStartUtc.ToString('o'); gameProcesses = @($observedGame); gameProcessesRecordedUtc = $launchUtc.ToString('o'); gameProcessesLaunchAttemptId = 'launch-1'; launchAttemptId = 'launch-1'; launchDispatchedUtc = $launchUtc.ToString('o') }
    & $mo2Module { param($state, $boundary) Reset-MO2GameProcessStateForLaunch -Data $state -LaunchAttemptId 'launch-2' -LaunchDispatchedUtc $boundary -PreLaunchGameProcesses @() } $relaunchState ([DateTimeOffset]::UtcNow.ToString('o'))
    Assert-MO2Test (@($relaunchState.gameProcesses).Count -eq 0 -and @($relaunchState.gameProcessHistory).Count -eq 1 -and $relaunchState.gameProcessHistory[0].launchAttemptId -eq 'launch-1' -and $relaunchState.launchAttemptId -eq 'launch-2') 'retained relaunch archives prior game identities and opens a distinct current-launch identity set'
    $nextObservedGame = [pscustomobject]@{ id = 206; name = $observedGame.name; path = $observedGame.path; startTime = [DateTimeOffset]::UtcNow.AddSeconds(1).UtcDateTime.ToString('o') }
    $nextLaunchAdoption = & $mo2Module { param($cfg, $state, $owner, $processes) $factory = { @($owner.targets[0]) }.GetNewClosure(); Get-MO2ObservedGameProcessAdoption -Config $cfg -Owned ([pscustomobject]@{ data = $state }) -Processes $processes -OwnerProcessInventoryFactory $factory } $config $relaunchState $launchOwner @($nextObservedGame)
    Assert-MO2Test ($nextLaunchAdoption.eligible -and $nextLaunchAdoption.records[0].id -eq 206) 'a retained second launch can adopt its new exact game identity without reusing the archived active set'
    $offsetRecorded = $observedGame | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $offsetRecorded.startTime = ([DateTimeOffset]::Parse([string]$observedGame.startTime)).ToUniversalTime().ToString('o')
    $roundTripResolution = & $mo2Module { param($recorded, $current) Resolve-MO2RecordedGameProcessTargets -Recorded @($recorded) -Current @($current) } $offsetRecorded $observedGame
    $changedInstant = $observedGame | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $changedInstant.startTime = ([DateTimeOffset]::Parse([string]$observedGame.startTime)).AddSeconds(1).UtcDateTime.ToString('o')
    $changedInstantResolution = & $mo2Module { param($recorded, $current) Resolve-MO2RecordedGameProcessTargets -Recorded @($recorded) -Current @($current) } $offsetRecorded $changedInstant
    Assert-MO2Test ($roundTripResolution.ok -and -not $changedInstantResolution.ok -and $changedInstantResolution.reason -eq 'process-start-time-mismatch') 'game identity compares the normalized persisted instant while still rejecting a genuinely changed start time'
    $moduleSource = Get-Content -LiteralPath (Join-Path $packageRoot 'MO2Control.psm1') -Raw
    $qualifiedGameCommitCalls = @([regex]::Matches($moduleSource, "[$]null = Set-MO2OwnedSessionGameProcesses[^`r`n]+-Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc'"))
    $allGameCommitCalls = @([regex]::Matches($moduleSource, '[$]null = Set-MO2OwnedSessionGameProcesses[^`r`n]+'))
    Assert-MO2Test ($qualifiedGameCommitCalls.Count -eq 2 -and $allGameCommitCalls.Count -eq 2) 'both status and synchronous launch durably co-write verified game identity with the running transition'
    Assert-MO2Test ($moduleSource -match 'processPath' -and $moduleSource -match 'processStartTime') 'launch and detached-owner adoption persist exact MO2 path and start-time identity'
    Assert-MO2Test (@([regex]::Matches($moduleSource, 'Invoke-MO2OwnedSessionMutation -Owned [$]owned -Action')).Count -eq 4) 'launch, open, terminate-game, and terminate all serialize current lifecycle authority before process mutation'
    Assert-MO2Test ($moduleSource -match 'param\([$]CurrentOwned, [$]MutationAction\)' -and $moduleSource -match 'Invoke-WithMO2LeaseTransitionLock[^\r\n]+-Action [$]lockedMutation -ArgumentList @\([$]Owned, [$]Action\)') 'serialized lifecycle mutation passes its caller action explicitly without colliding with the lock wrapper Action parameter'
    Assert-MO2Test ($moduleSource -notmatch "Set-MO2OwnedSessionOwner -Owned[^`r`n]+exact MO2 process observed after open" -and $moduleSource -match 'Resolve-MO2OwnedProcessTarget[^\r\n]+-AdoptDetachedOwner') 'synchronous open preserves its dispatch-bound owner tuple unless the explicit detached-owner proof succeeds'
    $launchSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2Launch \{.*?\n\}').Value
    $openSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2Open \{.*?\n\}').Value
    Assert-MO2Test ($launchSource -notmatch 'if \([$]ownerResolution[.]adopted\) \{\s*[$]owned = Get-MO2OwnedSession' -and
        $openSource -notmatch 'if \([$]observedResolution[.]adopted\) \{\s*[$]owned = Get-MO2OwnedSession' -and
        @([regex]::Matches($launchSource, 'Get-MO2SynchronousCompletionSupersession')).Count -eq 2 -and
        @([regex]::Matches($openSource, 'Get-MO2SynchronousCompletionSupersession')).Count -eq 2) 'synchronous launch/open keep their initiating post-handoff generation and classify stale terminal writes without adopting newer authority'
    Assert-MO2Test ($moduleSource -match 'Write-MO2SessionManifestProjection -SessionData [$]updated' -and $moduleSource -notmatch '(?s)Write-MO2OwnedSessionAtomic[^}]+Write-MO2JsonAtomic -Path [$]manifestPath') 'ownership-lock and session-manifest lifecycle projection share one serialized generation boundary'
    $gamePersistenceSource = [regex]::Match($moduleSource, '(?s)function Set-MO2OwnedSessionGameProcesses \{.*?\n\}').Value
    Assert-MO2Test ($gamePersistenceSource -match 'Invoke-MO2OwnedSessionMutation' -and $gamePersistenceSource -match 'Resolve-MO2OwnedProcessTarget' -and $gamePersistenceSource.IndexOf('Resolve-MO2OwnedProcessTarget', [StringComparison]::Ordinal) -lt $gamePersistenceSource.IndexOf('gameProcesses -NotePropertyValue', [StringComparison]::Ordinal)) 'game-process persistence resolves one exact live MO2 owner inside the serialized transition before changing running state'
    $terminationCalls = [Collections.Generic.List[string]]::new()
    $changedLiveOwner = [pscustomobject]@{ id = 101; name = 'MO2ControlFixtureProcess'; path = $mo2Exe; startTime = $ownerStartUtc.AddMinutes(1).ToString('o') }
    $replacementBinding = { param($processId) [pscustomobject]@{ available = $true; reason = 'bound'; process = [pscustomobject]@{ id = $processId }; record = $changedLiveOwner } }.GetNewClosure()
    $replacementTerminator = { param($process) $terminationCalls.Add([string]$process.id) }.GetNewClosure()
    $replacementRace = & $mo2Module { param($cfg, $owned, $target, $binding, $terminator) Invoke-MO2VerifiedForceTermination -Config $cfg -Owned $owned -Target $target -BindingFactory $binding -TerminationAction $terminator } $config $launchingOwned $launchOwner.targets[0] $replacementBinding $replacementTerminator
    Assert-MO2Test (-not $replacementRace.ok -and $replacementRace.reason -eq 'recorded-owner-start-time-mismatch' -and $terminationCalls.Count -eq 0) 'force termination rejects a changed live identity after the earlier inspection without invoking termination'
    Assert-MO2Test ($moduleSource -match 'Invoke-MO2VerifiedForceTermination .* -Target \$targets\[0\]' -and $moduleSource -match '\$binding[.]process[.]Kill\(\)') 'terminate rebinds the live process and kills only through its retained exact process handle'
    $gameTerminationCalls = [Collections.Generic.List[string]]::new()
    $changedLiveGame = [pscustomobject]@{ id = [int]$observedGame.id; name = [string]$observedGame.name; path = [string]$observedGame.path; startTime = ([DateTimeOffset]::Parse([string]$observedGame.startTime)).AddMinutes(1).UtcDateTime.ToString('o') }
    $gameReplacementBinding = { param($processId) [pscustomobject]@{ available = $true; reason = 'bound'; process = [pscustomobject]@{ id = $processId }; record = $changedLiveGame } }.GetNewClosure()
    $gameReplacementTerminator = { param($process) $gameTerminationCalls.Add([string]$process.id) }.GetNewClosure()
    $gameReplacementRace = & $mo2Module { param($cfg, $owned, $target, $binding, $terminator) Invoke-MO2VerifiedGameTerminationSet -Config $cfg -Owned $owned -Targets @($target) -BindingFactory $binding -TerminationAction $terminator } $config $launchingOwned $observedGame $gameReplacementBinding $gameReplacementTerminator
    Assert-MO2Test (-not $gameReplacementRace.ok -and $gameReplacementRace.reason -eq 'process-start-time-mismatch' -and $gameTerminationCalls.Count -eq 0) 'terminate-game rejects a changed live game identity after inspection without invoking termination'
    Assert-MO2Test ($moduleSource -match 'Invoke-MO2VerifiedGameTerminationSet .* -Targets \$targets' -and $moduleSource -notmatch 'Stop-Process -Id \(\[int\]\$target[.]id\)') 'terminate-game rebinds every game process and terminates only through retained exact process handles'
    $gameCloseCalls = [Collections.Generic.List[string]]::new()
    $gameReplacementCloser = { param($process) $gameCloseCalls.Add([string]$process.id) }.GetNewClosure()
    $gameCloseReplacementRace = & $mo2Module { param($cfg, $owned, $target, $binding, $closer) Invoke-MO2VerifiedGameCloseRequestSet -Config $cfg -Owned $owned -Targets @($target) -BindingFactory $binding -CloseAction $closer } $config $launchingOwned $observedGame $gameReplacementBinding $gameReplacementCloser
    Assert-MO2Test (-not $gameCloseReplacementRace.ok -and $gameCloseReplacementRace.reason -eq 'process-start-time-mismatch' -and $gameCloseCalls.Count -eq 0) 'graceful game close rejects a changed live identity after inspection without invoking CloseMainWindow'
    $recordedCloseOwned = $launchingOwned | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $recordedCloseOwned.data.gameProcesses = @($observedGame)
    $unrecordedGame = $observedGame | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unrecordedGame.id = [int]$observedGame.id + 1
    $unrecordedGame.startTime = ([DateTimeOffset]::Parse([string]$observedGame.startTime)).AddSeconds(1).UtcDateTime.ToString('o')
    $unrecordedInspection = [pscustomobject]@{ processes = [pscustomobject]@{ game = @($observedGame, $unrecordedGame); mo2 = @($launchOwner.targets) } }
    $unrecordedCloseCalls = [Collections.Generic.List[string]]::new()
    $unrecordedCloser = { param($process) $unrecordedCloseCalls.Add([string]$process.id) }.GetNewClosure()
    $unrecordedClose = & $mo2Module { param($cfg, $owned, $data, $inspection, $closer) Invoke-MO2CurrentGameCloseRequest -Config $cfg -Owned $owned -CurrentData $data -CurrentInspection $inspection -CloseAction $closer } $config $recordedCloseOwned $recordedCloseOwned.data $unrecordedInspection $unrecordedCloser
    Assert-MO2Test (-not $unrecordedClose.ok -and $unrecordedClose.reason -eq 'unrecorded-game-process-present' -and $unrecordedCloseCalls.Count -eq 0) 'graceful game close refuses a configured but session-unrecorded process without invoking CloseMainWindow'
    $missingOwnerInspection = [pscustomobject]@{ processes = [pscustomobject]@{ game = @($observedGame); mo2 = @() } }
    $missingOwnerClose = & $mo2Module { param($cfg, $owned, $data, $inspection, $closer) Invoke-MO2CurrentGameCloseRequest -Config $cfg -Owned $owned -CurrentData $data -CurrentInspection $inspection -CloseAction $closer } $config $recordedCloseOwned $recordedCloseOwned.data $missingOwnerInspection $unrecordedCloser
    Assert-MO2Test (-not $missingOwnerClose.ok -and $missingOwnerClose.reason -eq 'mo2-owner-changed-before-game-close' -and $unrecordedCloseCalls.Count -eq 0) 'graceful game close requires the exact current MO2 owner before invoking CloseMainWindow'

    $dialogAuthority = & $mo2Module {
        param($cfg, $owned, $ownerRecord)
        $originalSnapshot = (Get-Command Get-MO2WindowSnapshot -CommandType Function).ScriptBlock
        $originalTexts = (Get-Command Get-MO2WindowTextElements -CommandType Function).ScriptBlock
        $originalKind = (Get-Command Get-MO2KnownDialogKind -CommandType Function).ScriptBlock
        $originalButtons = (Get-Command Get-MO2NamedButtons -CommandType Function).ScriptBlock
        $script:DialogAuthorityAttempts = 0
        $script:DialogAuthorityExecutions = 0
        try {
            Set-Item Function:script:Get-MO2WindowSnapshot { @() }
            Set-Item Function:script:Get-MO2WindowTextElements { @('fixture') }
            Set-Item Function:script:Get-MO2KnownDialogKind { 'failed-to-run' }
            Set-Item Function:script:Get-MO2NamedButtons { param($Window, $Name) @([pscustomobject]@{ Name=$Name }) }
            $window = [pscustomobject]@{ Current=[pscustomobject]@{ AutomationId='Dialog'; Name='fixture failed to run'; NativeWindowHandle=42 } }
            $binding = { param($ProcessId) [pscustomobject]@{ available=$true; reason='bound'; process=[pscustomobject]@{ id=$ProcessId }; record=$ownerRecord } }.GetNewClosure()
            $windows = { param($Binding) @($window) }.GetNewClosure()
            $guardedAction = {
                param($AuthorityOwned, $Binding, $Action, [object[]]$Arguments)
                $script:DialogAuthorityAttempts++
                if ($script:DialogAuthorityAttempts -gt 1) { throw 'lease transition is stale: fixture' }
                $script:DialogAuthorityExecutions++
                return $true
            }
            $result = Invoke-MO2RetainedSessionDialogCleanup -Config $cfg -Owned $owned -Processes @($ownerRecord) -TimeoutSeconds 1 -BindingFactory $binding -WindowFactory $windows -OwnedAction $guardedAction
            [pscustomobject]@{ result=$result; attempts=$script:DialogAuthorityAttempts; executions=$script:DialogAuthorityExecutions }
        }
        finally {
            Set-Item Function:script:Get-MO2WindowSnapshot -Value $originalSnapshot
            Set-Item Function:script:Get-MO2WindowTextElements -Value $originalTexts
            Set-Item Function:script:Get-MO2KnownDialogKind -Value $originalKind
            Set-Item Function:script:Get-MO2NamedButtons -Value $originalButtons
            Remove-Variable -Scope Script -Name DialogAuthorityAttempts, DialogAuthorityExecutions -ErrorAction SilentlyContinue
        }
    } $config $launchingOwned $launchOwner.targets[0]
    Assert-MO2Test (-not $dialogAuthority.result.cleared -and $dialogAuthority.result.blockedReason -eq 'stale-session-generation' -and $dialogAuthority.attempts -eq 2 -and $dialogAuthority.executions -eq 1) 'retained dialog cleanup revalidates current generation before every UI action and stops between controls when authority changes'
    $stopGameSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2StopGame \{.*?\n\}').Value
    $stopSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2Stop \{.*?\n\}').Value
    $ownedCloseSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2OwnedGameCloseRequest \{.*?\n\}').Value
    Assert-MO2Test ($stopGameSource -match 'Invoke-MO2OwnedGameCloseRequest -Config \$Config -Owned \$owned' -and
        $stopSource -match 'Invoke-MO2OwnedGameCloseRequest -Config \$Config -Owned \$owned' -and
        $stopGameSource -notmatch 'Invoke-MO2OwnedGameCloseRequest[^\r\n]+-Targets' -and
        $stopSource -notmatch 'Invoke-MO2OwnedGameCloseRequest[^\r\n]+-Targets' -and
        $ownedCloseSource -match 'Invoke-MO2CurrentGameCloseRequest[^\r\n]+-CurrentData \$currentData' -and
        $moduleSource -match 'Resolve-MO2OwnedProcessTarget -Config \$Config -Owned \$Owned -Processes @\(\$CurrentInspection[.]processes[.]mo2\)' -and
        $moduleSource -match 'Resolve-MO2RecordedGameProcessTargets -Recorded @\(\$CurrentData[.]gameProcesses\)' -and
        $stopGameSource -notmatch 'Get-Process -Id' -and $stopSource -notmatch 'Get-Process -Id') 'stop-game and stop close only the serialized session-recorded game set through retained live handles'
    $recoverCloseSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2RecoverClose \{.*?\n\}').Value
    Assert-MO2Test (@([regex]::Matches($recoverCloseSource, '\$owned = Get-MO2OwnedSession -Config \$Config -SessionId \$sessionId')).Count -eq 1 -and $recoverCloseSource -match 'Invoke-MO2CooperativeClose -Config \$Config -Owned \$owned' -and $recoverCloseSource -match 'Set-MO2OwnedSessionStatus -Owned \$owned') 'recovery close preserves one initiating owned-session generation through process action and completion write'
    $terminateGameSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2TerminateGame \{.*?\n\}').Value
    $serializedTerminationIndex = $terminateGameSource.IndexOf('Invoke-MO2OwnedSessionMutation', [StringComparison]::Ordinal)
    $currentOwnerGuardIndex = $terminateGameSource.IndexOf('$currentOwnerResolution = Resolve-MO2OwnedProcessTarget', [StringComparison]::Ordinal)
    $gameMutationIndex = $terminateGameSource.IndexOf('$verified = Invoke-MO2VerifiedGameTerminationSet', [StringComparison]::Ordinal)
    Assert-MO2Test ($serializedTerminationIndex -ge 0 -and $currentOwnerGuardIndex -gt $serializedTerminationIndex -and $gameMutationIndex -gt $currentOwnerGuardIndex) 'terminate-game revalidates the exact live MO2 owner inside the serialized transition before requesting game termination'

    $missingProfile = Invoke-MO2Validate -Config $config -Profile 'Does Not Exist'
    Assert-MO2Test (-not $missingProfile.ok) 'missing exact profile blocks validation'
    Assert-MO2Test (@($missingProfile.checks | Where-Object { $_.name -eq 'requested-profile' -and $_.status -eq 'fail' }).Count -eq 1) 'profile fallback is never accepted'

    '{broken json' | Set-Content -LiteralPath $gameData -Encoding utf8
    $invalidRootBuilder = Invoke-MO2Validate -Config $config
    Assert-MO2Test (-not $invalidRootBuilder.ok) 'invalid active RootBuilder JSON blocks validation'
    Assert-MO2Test (@($invalidRootBuilder.checks | Where-Object { $_.name -eq 'rootbuilder-json' -and $_.status -eq 'fail' }).Count -eq 1) 'RootBuilder failure is attributable'

    '{}' | Set-Content -LiteralPath $gameData -Encoding utf8
    $transitionPath = "$($config.session.lockFile).transition.lock"
    $heldTransition = [IO.File]::Open($transitionPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $transitionTimedOut = $false
    try {
        try {
            & $mo2Module { param($path) Invoke-WithMO2LeaseTransitionLock -LockPath $path -TimeoutMilliseconds 150 -Action { 'unexpected' } } ([string]$config.session.lockFile) | Out-Null
        }
        catch {
            $transitionTimedOut = $_.Exception.Message -like 'Timed out waiting for the MO2 lease transition lock:*'
        }
    }
    finally {
        $heldTransition.Dispose()
    }
    Assert-MO2Test $transitionTimedOut 'lease transitions fail boundedly while another writer owns the companion lock'

    $accessDryRun = Invoke-MO2RequestAccess -Config $config -Label 'first task' -TaskId 'fixture-task' -RuntimeRoute OCU -EstimatedMinutes 15 -WhatIf
    Assert-MO2Test ($accessDryRun.ok -and $accessDryRun.state -eq 'dry-run' -and $accessDryRun.data.estimateIsAdvisory -and $accessDryRun.data.access.ownerTaskId -eq 'fixture-task' -and $accessDryRun.data.access.runtimeRoute.id -eq 'OCU') 'access request dry-run reports an advisory estimate, task identity, and exact runtime route without locking'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'access request dry-run creates no lock'
    $missingRuntimeRoute = & (Join-Path $packageRoot 'Invoke-MO2Control.ps1') request-access -ConfigPath $configPath -Label 'missing route' -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-MO2Test (-not $missingRuntimeRoute.ok -and $missingRuntimeRoute.state -eq 'missing-runtime-route' -and $missingRuntimeRoute.data.requiredParameter -eq 'RuntimeRoute') 'entry point refuses an access request without one explicit runtime route'
    $entryAccessDryRun = & (Join-Path $packageRoot 'Invoke-MO2Control.ps1') request-access -ConfigPath $configPath -Label 'approval fixture' -TaskId 'entry-fixture-task' -RuntimeRoute SteamVR -EstimatedMinutes 5 -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-MO2Test ($entryAccessDryRun.ok -and $entryAccessDryRun.data.access.ownerTaskId -eq 'entry-fixture-task' -and $entryAccessDryRun.data.configuration.exists -and $entryAccessDryRun.data.approval.reusableApprovalEligible -and $entryAccessDryRun.data.approval.reusablePrefix[5] -eq 'request-access') 'dictionary-backed entry-point results retain task identity, configuration, and approval metadata'

    $entryHumanDryRun = & (Join-Path $packageRoot 'Invoke-MO2Control.ps1') request-access -ConfigPath $configPath -AccessKind human -Profile Codex -TaskId 'human-fixture-task' -Label 'human fixture' -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-MO2Test ($entryHumanDryRun.ok -and $entryHumanDryRun.data.access.accessKind -eq 'human' -and $entryHumanDryRun.data.access.profile -eq 'Codex' -and $entryHumanDryRun.data.access.humanMutationTaskId -eq 'human-fixture-task' -and -not [string]::IsNullOrWhiteSpace([string]$entryHumanDryRun.data.access.humanMutationId) -and $null -eq $entryHumanDryRun.data.access.runtimeRoute) 'human access binds the exact selected profile and private mutation capability to one recipient task without inventing a runtime route'

    $humanProcess = Start-Process -FilePath $mo2Exe -ArgumentList @('/d', '/c', 'ping -n 30 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
    try {
        $humanProcessDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $humanInspection = Invoke-MO2Inspect -Config $config
            if (@($humanInspection.data.processes.mo2 | Where-Object id -eq $humanProcess.Id).Count -eq 1) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $humanProcessDeadline)

        $humanAccess = Invoke-MO2RequestAccess -Config $config -AccessKind human -Profile Codex -TaskId 'human-fixture-task' -Label 'human fixture'
        $humanAccessId = [string]$humanAccess.data.access.accessId
        $humanLeaseId = [string]$humanAccess.data.access.leaseId
        $humanMutationId = [string]$humanAccess.data.access.humanMutationId
        Assert-MO2Test ($humanAccess.ok -and $humanAccess.data.access.accessKind -eq 'human' -and $humanAccess.data.access.profile -eq 'Codex') 'human access can reserve an already-open exact MO2 profile'
        $humanLockText = Get-Content -LiteralPath $config.session.lockFile -Raw
        Assert-MO2Test (-not ($humanLockText -match [regex]::Escape($humanMutationId)) -and ($humanLockText | ConvertFrom-Json).humanMutationHash.Length -eq 64) 'durable human lease stores only the private credential hash'
        $humanStatus = Invoke-MO2AccessStatus -Config $config
        Assert-MO2Test (-not (($humanStatus | ConvertTo-Json -Depth 16 -Compress) -match [regex]::Escape($humanMutationId))) 'public access status never discloses the private human mutation credential'
        $humanPrepare = Invoke-MO2Prepare -Config $config -AccessId $humanAccessId -Profile Codex -WhatIf
        Assert-MO2Test (-not $humanPrepare.ok -and $humanPrepare.state -eq 'human-lease-session-forbidden') 'human access cannot be converted into an automation launch session'

        $publicLeaseRejected = $false
        try { Invoke-MO2ValidateHumanMutation -Config $config -HumanMutationId $humanLeaseId -Profile Codex -TaskId 'human-fixture-task' | Out-Null }
        catch { $publicLeaseRejected = $_.Exception.Message -eq 'The supplied human mutation credential is not authorized for this task.' }
        Assert-MO2Test $publicLeaseRejected 'public LeaseId is coordination metadata and cannot authorize mutation'
        $wrongTaskRejected = $false
        try { Invoke-MO2ValidateHumanMutation -Config $config -HumanMutationId $humanMutationId -Profile Codex -TaskId 'other-task' | Out-Null }
        catch { $wrongTaskRejected = $_.Exception.Message -eq 'The supplied human mutation credential is not authorized for this task.' }
        Assert-MO2Test $wrongTaskRejected 'private human mutation credential is rejected outside its recipient task'

        $unclassifiedRefresh = Invoke-MO2Refresh -Config $config -HumanMutationId $humanMutationId -Profile Codex -TaskId 'human-fixture-task' -WhatIf
        Assert-MO2Test (-not $unclassifiedRefresh.ok -and $unclassifiedRefresh.state -eq 'known-ground-state-required') 'human refresh refuses an unclassified non-MO2 fixture window state'

        $originalMO2Executable = [string]$config.mo2.executable
        $env:MO2_REFRESH_FIXTURE_EXE = $mo2Exe
        $config.mo2.executable = '%MO2_REFRESH_FIXTURE_EXE%'
        $humanLiveActions = & $mo2Module {
            param($fixtureConfig, $fixtureMutationId)
            $originalWindowSnapshot = (Get-Command Get-MO2WindowSnapshot -CommandType Function).ScriptBlock
            $originalRefreshHelper = (Get-Command Invoke-MO2RefreshHelperProcess -CommandType Function).ScriptBlock
            try {
                Set-Item -Path Function:script:Get-MO2WindowSnapshot -Value {
                    param($Processes)
                    @([pscustomobject][ordered]@{ processId=[int]$Processes[0].id; handle=101; title='Mod Organizer'; className='Qt'; visible=$true; automationAvailable=$true; automationId='MainWindow'; buttons=@(); texts=@(); dialogKind=$null })
                }
                Set-Item -Path Function:script:Invoke-MO2RefreshHelperProcess -Value {
                    param($Path, $WorkingDirectory, $TimeoutSeconds)
                    [pscustomobject][ordered]@{ pid=9911; exited=$true; exitCode=0 }
                }
                [pscustomobject]@{
                    validation = Invoke-MO2ValidateHumanMutation -Config $fixtureConfig -HumanMutationId $fixtureMutationId -Profile Codex -TaskId 'human-fixture-task'
                    refresh = Invoke-MO2Refresh -Config $fixtureConfig -HumanMutationId $fixtureMutationId -Profile Codex -TaskId 'human-fixture-task'
                }
            }
            finally {
                Set-Item -Path Function:script:Get-MO2WindowSnapshot -Value $originalWindowSnapshot
                Set-Item -Path Function:script:Invoke-MO2RefreshHelperProcess -Value $originalRefreshHelper
            }
        } $config $humanMutationId
        $humanValidation = $humanLiveActions.validation
        $humanRefresh = $humanLiveActions.refresh
        $config.mo2.executable = $originalMO2Executable
        Remove-Item Env:MO2_REFRESH_FIXTURE_EXE -ErrorAction SilentlyContinue
        Assert-MO2Test ($humanValidation.ok -and $humanValidation.state -eq 'human-mutation-authorized' -and $humanValidation.data.mo2Open -and $humanValidation.data.refreshRequiredAfterMutation) 'human lease authorizes exact-profile mutation while one unblocked exact MO2 process is open'
        Assert-MO2Test ($humanRefresh.ok -and $humanRefresh.state -eq 'refreshed' -and $humanRefresh.data.authorityKind -eq 'human-mutation' -and $humanRefresh.data.primaryRetained -and $humanRefresh.data.postconditionVerified) 'private task-bound human authority authorizes exact-primary CLI refresh with closed-game postconditions'
        Assert-MO2Test ([string]$humanRefresh.data.plan.path -ceq [IO.Path]::GetFullPath($mo2Exe)) 'refresh expands environment variables in the configured MO2 executable path'
        Assert-MO2Test ((Test-Path -LiteralPath $humanRefresh.data.receiptPath -PathType Leaf) -and (Get-Content -LiteralPath $humanRefresh.data.receiptPath -Raw | ConvertFrom-Json).command.arguments[0] -eq 'refresh') 'human refresh preserves a durable exact-command receipt'
        Assert-MO2Test (-not ((Get-Content -LiteralPath $humanRefresh.data.receiptPath -Raw) -match [regex]::Escape($humanMutationId))) 'human refresh receipt records only public lease identity and never the private mutation credential'

        $buildData = Join-Path $rootBuilderData 'BuildData.json'
        '{}' | Set-Content -LiteralPath $buildData -Encoding utf8
        $uncertainRefresh = Invoke-MO2Refresh -Config $config -HumanMutationId $humanMutationId -Profile Codex -TaskId 'human-fixture-task' -WhatIf
        Assert-MO2Test (-not $uncertainRefresh.ok -and $uncertainRefresh.state -eq 'known-ground-state-required') 'refresh routes active RootBuilder deployment to the known-ground-state recovery path'
        Remove-Item -LiteralPath $buildData -Force

        $releaseStdOut = Join-Path $fixture 'human-release.stdout.json'
        $releaseStdErr = Join-Path $fixture 'human-release.stderr.txt'
        $releaseProbePath = Join-Path $fixture 'human-release.probe.json'
        $releaseProbeScript = Join-Path $fixture 'Invoke-HumanReleaseProbe.ps1'
        @'
param(
    [Parameter(Mandatory)][string]$TransitionLockPath,
    [Parameter(Mandatory)][string]$ProbePath,
    [Parameter(Mandatory)][string]$EntryPoint,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$AccessId
)
$ErrorActionPreference = 'Stop'
try {
    $unexpected = [IO.File]::Open($TransitionLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $unexpected.Dispose()
    [IO.File]::WriteAllText($ProbePath, '{"state":"lock-acquired-unexpected"}', [Text.UTF8Encoding]::new($false))
    exit 23
}
catch [IO.IOException] {
    [IO.File]::WriteAllText($ProbePath, '{"state":"transition-lock-contended"}', [Text.UTF8Encoding]::new($false))
}
& $EntryPoint release-access -ConfigPath $ConfigPath -AccessId $AccessId -Compact -NoExit
'@ | Set-Content -LiteralPath $releaseProbeScript -Encoding utf8
        $releaseAction = {
            $transitionLockPath = ([string]$config.session.lockFile) + '.transition.lock'
            $releaseProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $releaseProbeScript, '-TransitionLockPath', $transitionLockPath, '-ProbePath', $releaseProbePath, '-EntryPoint', (Join-Path $packageRoot 'Invoke-MO2Control.ps1'), '-ConfigPath', $configPath, '-AccessId', $humanAccessId) -RedirectStandardOutput $releaseStdOut -RedirectStandardError $releaseStdErr -PassThru
            $probeDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $releaseProbePath -PathType Leaf) -and [DateTime]::UtcNow -lt $probeDeadline) { Start-Sleep -Milliseconds 25 }
            if (-not (Test-Path -LiteralPath $releaseProbePath -PathType Leaf)) { throw 'Release child did not reach the exact transition-lock probe.' }
            $probe = Get-Content -LiteralPath $releaseProbePath -Raw | ConvertFrom-Json
            Start-Sleep -Milliseconds 150
            [pscustomobject][ordered]@{ pid = $releaseProcess.Id; lockProbeState = [string]$probe.state; blockedDuringMutation = -not $releaseProcess.HasExited }
        }
        $guardedReleaseProbe = & $mo2Module {
            param($fixtureConfig, $fixtureMutationId, $fixtureAction)
            $originalWindowSnapshot = (Get-Command Get-MO2WindowSnapshot -CommandType Function).ScriptBlock
            try {
                Set-Item -Path Function:script:Get-MO2WindowSnapshot -Value {
                    param($Processes)
                    @([pscustomobject][ordered]@{ processId=[int]$Processes[0].id; handle=101; title='Mod Organizer'; className='Qt'; visible=$true; automationAvailable=$true; automationId='MainWindow'; buttons=@(); texts=@(); dialogKind=$null })
                }
                Invoke-MO2HumanMutationTransaction -Config $fixtureConfig -HumanMutationId $fixtureMutationId -Profile Codex -TaskId 'human-fixture-task' -Action $fixtureAction
            }
            finally {
                Set-Item -Path Function:script:Get-MO2WindowSnapshot -Value $originalWindowSnapshot
            }
        } $config $humanMutationId $releaseAction
        $releaseProbe = @($guardedReleaseProbe.actionResult)[0]
        Assert-MO2Test ($guardedReleaseProbe.ok -and $releaseProbe.lockProbeState -eq 'transition-lock-contended' -and $releaseProbe.blockedDuringMutation) 'release child reaches and contends on the exact transition lock before the authorized profile mutation returns'
        $releaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((-not (Test-Path -LiteralPath $releaseStdOut -PathType Leaf) -or (Get-Item -LiteralPath $releaseStdOut).Length -eq 0) -and [DateTime]::UtcNow -lt $releaseDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $releaseStdOut -PathType Leaf) -or (Get-Item -LiteralPath $releaseStdOut).Length -eq 0) { throw 'Guarded release fixture did not complete after the human mutation released the transition lock.' }
        $humanRelease = Get-Content -LiteralPath $releaseStdOut -Raw | ConvertFrom-Json
        Assert-MO2Test ($humanRelease.ok -and $humanRelease.state -eq 'access-released' -and $humanRelease.data.liveStateRetained -and @($humanRelease.data.processes.mo2).Count -eq 1) 'human Release removes only coordination state while leaving the live MO2 process untouched'
    }
    finally {
        if (-not $humanProcess.HasExited) { $humanProcess.Kill($true); $humanProcess.WaitForExit(5000) | Out-Null }
    }

    $access = Invoke-MO2RequestAccess -Config $config -Label 'first task' -RuntimeRoute SteamVRNull -EstimatedMinutes 15
    $accessId = [string]$access.data.access.accessId
    $leaseId = [string]$access.data.access.leaseId
    Assert-MO2Test ($access.ok -and $access.state -eq 'access-acquired' -and -not [string]::IsNullOrWhiteSpace($accessId)) 'first task atomically acquires access'
    Assert-MO2Test (-not [string]::IsNullOrWhiteSpace($leaseId) -and $leaseId -ne $accessId) 'access receipt separates public lease identity from the bearer credential'
    Assert-MO2Test ([long]$access.data.access.generation -eq 1L) 'new access lease starts at generation one'
    Assert-MO2Test ($access.data.access.runtimeRoute.id -eq 'SteamVRNull' -and $access.data.access.runtimeRoute.runtimeFamily -eq 'SteamVR' -and $access.data.access.runtimeRoute.requiresNullHmd) 'null-HMD access records the SteamVR family and explicit null-HMD requirement'
    $nullRouteProviderValid = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $accessId
    Assert-MO2Test ($nullRouteProviderValid.ok -and @($nullRouteProviderValid.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'pass' }).Count -eq 1) 'null-HMD route accepts a profile with its OCU provider disabled'
    @('+Skyrim Script Extender for VR (SKSEVR)', '+OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $nullRouteProviderRejected = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $accessId
    Assert-MO2Test (-not $nullRouteProviderRejected.ok -and @($nullRouteProviderRejected.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'fail' }).Count -eq 1) 'null-HMD route rejects an enabled profile-local OCU provider'
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider', '+Unknown OpenVR Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $unclassifiedProviderRejected = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $accessId
    $unclassifiedInventory = @($unclassifiedProviderRejected.data.runtimeProviders.providers | Where-Object classification -eq 'unclassified-openvr-provider')
    Assert-MO2Test (-not $unclassifiedProviderRejected.ok -and $unclassifiedInventory.Count -eq 1 -and $unclassifiedInventory[0].enabled -and @($unclassifiedProviderRejected.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'fail' }).Count -eq 1) 'null-HMD route rejects an enabled unclassified root OpenVR provider'
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $busyAccess = Invoke-MO2RequestAccess -Config $config -Label 'second task' -RuntimeRoute OCU -EstimatedMinutes 5
    Assert-MO2Test (-not $busyAccess.ok -and $busyAccess.state -eq 'access-busy' -and $busyAccess.data.retryable) 'second task receives a retryable access-busy result'
    Assert-MO2Test ($busyAccess.data.current.leaseId -eq $leaseId -and $busyAccess.data.current.estimatedReleaseUtc -and $busyAccess.data.current.runtimeRoute.id -eq 'SteamVRNull' -and $busyAccess.data.requestedRuntimeRoute.id -eq 'OCU') 'busy result communicates both incompatible runtime routes, public lease identity, and advisory estimate'
    Assert-MO2Test ($busyAccess.data.current.PSObject.Properties.Name -notcontains 'accessId' -and (($busyAccess | ConvertTo-Json -Depth 12) -notmatch [regex]::Escape($accessId))) 'busy result never discloses the bearer credential'

    $ownedAccess = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    Assert-MO2Test ($ownedAccess.ok -and $ownedAccess.state -eq 'access-owned' -and $ownedAccess.data.owned) 'access status proves exact ownership'
    Assert-MO2Test (-not $ownedAccess.data.access.estimateOverdue -and [string]$ownedAccess.data.access.estimatedReleaseUtc -match 'Z$') 'future advisory estimate survives JSON round-trip with UTC identity'
    $unownedAccess = Invoke-MO2AccessStatus -Config $config -AccessId 'access-wrong-credential'
    Assert-MO2Test ($unownedAccess.state -eq 'access-busy' -and -not $unownedAccess.data.owned -and (($unownedAccess | ConvertTo-Json -Depth 12) -notmatch 'access-wrong-credential')) 'status rejects a wrong credential without echoing it'
    $ownedValidation = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') validate -ConfigPath $configPath -AccessId $accessId -RequireClosed -NoExit | ConvertFrom-Json)
    Assert-MO2Test ($ownedValidation.ok -and @($ownedValidation.checks | Where-Object { $_.name -eq 'session-lock' -and $_.status -eq 'pass' }).Count -eq 1) 'validation accepts the exact owned access lease'
    $closedAlias = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') validate-closed -ConfigPath $configPath -AccessId $accessId -NoExit | ConvertFrom-Json)
    Assert-MO2Test ($closedAlias.ok -and $closedAlias.command -eq 'validate-closed') 'validate-closed is a working explicit alias for the closed-state precondition'
    $validationApproval = $ownedValidation.data.approval
    Assert-MO2Test ($validationApproval.reusableApprovalEligible -and -not $validationApproval.escalationUsuallyRequired -and @($validationApproval.reusablePrefix).Count -eq 6) 'validation exposes an exact reusable approval prefix'
    Assert-MO2Test ($validationApproval.reusablePrefix[1] -eq '-NoProfile' -and $validationApproval.reusablePrefix[2] -eq '-NonInteractive' -and $validationApproval.reusablePrefix[3] -eq '-File' -and $validationApproval.reusablePrefix[4] -eq [IO.Path]::GetFullPath((Join-Path $packageRoot 'Invoke-MO2Control.ps1')) -and $validationApproval.reusablePrefix[5] -eq 'validate') 'approval prefix keeps the literal host, entry point, and subcommand visible'
    $renewedAccess = Invoke-MO2RenewAccess -Config $config -AccessId $accessId -EstimatedMinutes 30
    Assert-MO2Test ($renewedAccess.ok -and $renewedAccess.state -eq 'access-renewed' -and $renewedAccess.data.access.estimatedDurationMinutes -eq 30) 'access renewal replaces the advisory estimate'
    Assert-MO2Test ([long]$renewedAccess.data.access.generation -eq 2L) 'access renewal advances the serialized lease generation'

    $explicitPrepared = Invoke-MO2Prepare -Config $config -Label 'explicit fixture test' -AccessId $accessId
    $explicitSessionId = [string]$explicitPrepared.data.session.sessionId
    Assert-MO2Test ($explicitPrepared.ok -and $explicitPrepared.data.explicitAccess -and $explicitPrepared.data.accessId -eq $accessId -and $explicitPrepared.data.session.runtimeRoute.id -eq 'SteamVRNull') 'prepare binds an explicitly owned access lease and preserves its runtime route'
    $boundAccessStatus = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    Assert-MO2Test ([long]$boundAccessStatus.data.access.generation -eq 3L -and $boundAccessStatus.data.access.sessionId -eq $explicitSessionId) 'session binding advances generation without losing lease identity'
    $boundSessionManifest = Get-Content -LiteralPath (Join-Path ([string]$explicitPrepared.data.sessionPath) 'session.json') -Raw | ConvertFrom-Json
    Assert-MO2Test ([long]$boundSessionManifest.generation -eq [long]$boundAccessStatus.data.access.generation -and $boundSessionManifest.sessionId -eq $explicitSessionId) 'initial session binding projects the authoritative generation into the retained manifest before returning success'
    $staleOwnedSession = & $mo2Module { param($fixtureConfig, $fixtureSessionId) Get-MO2OwnedSession -Config $fixtureConfig -SessionId $fixtureSessionId } $config $explicitSessionId
    $inSessionRenewal = Invoke-MO2RenewAccess -Config $config -AccessId $accessId -EstimatedMinutes 45
    $renewedSessionManifest = Get-Content -LiteralPath (Join-Path ([string]$explicitPrepared.data.sessionPath) 'session.json') -Raw | ConvertFrom-Json
    Assert-MO2Test ([long]$renewedSessionManifest.generation -eq [long]$inSessionRenewal.data.access.generation -and $renewedSessionManifest.estimatedDurationMinutes -eq 45) 'in-session access renewal projects the same generation and advisory metadata before returning success'
    $staleGameRecord = [pscustomobject]@{ id = 9191; name = 'MO2ControlImpossibleFixtureGame'; path = $fixtureGame; startTime = [DateTimeOffset]::UtcNow.ToString('o') }
    $staleWriterRejected = $false
    try { $null = & $mo2Module { param($fixtureConfig, $fixtureOwned, $game) Set-MO2OwnedSessionGameProcesses -Config $fixtureConfig -Owned $fixtureOwned -Processes @($game) -Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc' } $config $staleOwnedSession $staleGameRecord }
    catch { $staleWriterRejected = $_.Exception.Message -match 'lease transition is stale' }
    $postStaleWriteStatus = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    $postStaleWriteLock = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $postStaleGameCount = if ($postStaleWriteLock.PSObject.Properties['gameProcesses']) { @($postStaleWriteLock.gameProcesses).Count } else { 0 }
    Assert-MO2Test ($staleWriterRejected -and $inSessionRenewal.ok -and $postStaleWriteStatus.data.access.estimatedDurationMinutes -eq 45 -and [long]$postStaleWriteStatus.data.access.generation -eq 4L -and $postStaleWriteStatus.data.access.runtimeRoute.id -eq 'SteamVRNull' -and $postStaleWriteLock.status -ne 'running' -and $postStaleGameCount -eq 0) 'a stale game-adoption writer is rejected without replacing a concurrent lease renewal or lifecycle state'
    $staleMutationState = [pscustomobject]@{ calls = 0 }
    $staleMutationRejected = $false
    try {
        $null = & $mo2Module { param($fixtureOwned, $state) $action = { param($data) $state.calls++; [pscustomobject]@{ sessionData=$data; result=$true } }.GetNewClosure(); Invoke-MO2OwnedSessionMutation -Owned $fixtureOwned -Action $action } $staleOwnedSession $staleMutationState
    }
    catch { $staleMutationRejected = $_.Exception.Message -match 'lease transition is stale' }
    Assert-MO2Test ($staleMutationRejected -and $staleMutationState.calls -eq 0) 'renewal-stale launch or termination authority is rejected before its external process-action callback'
    $emptyReleaseInspection = { param($fixtureConfig, $currentData) [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @(); game = @() }; rootBuilder = [pscustomobject]@{ active = @() } } }
    $staleRelease = & $mo2Module { param($fixtureConfig, $owned, $sessionPath, $factory) Invoke-MO2ReleaseTransition -Config $fixtureConfig -Owned $owned -SessionId ([string]$owned.sessionId) -SessionPath $sessionPath -InspectionFactory $factory } $config $staleOwnedSession ([string]$explicitPrepared.data.sessionPath) $emptyReleaseInspection
    $lockAfterStaleRelease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    Assert-MO2Test (-not $staleRelease.ok -and $staleRelease.state -eq 'blocked' -and $lockAfterStaleRelease.sessionId -eq $explicitSessionId -and [long]$lockAfterStaleRelease.generation -eq [long]$inSessionRenewal.data.access.generation) 'a stale release cannot unbind a newer same-session lifecycle generation'
    $currentReleaseOwned = & $mo2Module { param($fixtureConfig, $fixtureSessionId) Get-MO2OwnedSession -Config $fixtureConfig -SessionId $fixtureSessionId } $config $explicitSessionId
    $activeReleaseInspection = { param($fixtureConfig, $currentData) [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @(); game = @([pscustomobject]@{ id = 9192; name = 'MO2ControlImpossibleFixtureGame'; path = $fixtureGame; startTime = [DateTimeOffset]::UtcNow.ToString('o') }) }; rootBuilder = [pscustomobject]@{ active = @() } } }.GetNewClosure()
    $activeRelease = & $mo2Module { param($fixtureConfig, $owned, $sessionPath, $factory) Invoke-MO2ReleaseTransition -Config $fixtureConfig -Owned $owned -SessionId ([string]$owned.sessionId) -SessionPath $sessionPath -InspectionFactory $factory } $config $currentReleaseOwned ([string]$explicitPrepared.data.sessionPath) $activeReleaseInspection
    $lockAfterActiveRelease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    Assert-MO2Test (-not $activeRelease.ok -and $activeRelease.state -eq 'blocked' -and $lockAfterActiveRelease.sessionId -eq $explicitSessionId) 'release repeats its live-process veto inside the serialized transition and retains a lifecycle that became active'
    $prematureAccessRelease = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    Assert-MO2Test (-not $prematureAccessRelease.ok -and $prematureAccessRelease.state -eq 'session-release-required') 'access cannot be released while a session is bound'
    $explicitReleased = Invoke-MO2Release -Config $config -SessionId $explicitSessionId
    Assert-MO2Test ($explicitReleased.ok -and $explicitReleased.state -eq 'session-released-access-retained' -and $explicitReleased.data.releaseAccessRequired) 'session release retains explicitly requested access'
    $accessOnlyStatus = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    Assert-MO2Test ($accessOnlyStatus.state -eq 'access-owned' -and $accessOnlyStatus.data.access.state -eq 'access-held' -and [string]::IsNullOrWhiteSpace([string]$accessOnlyStatus.data.access.sessionId)) 'released session returns the lock to access-only state'
    Assert-MO2Test ([long]$accessOnlyStatus.data.access.generation -eq 5L) 'session release advances the serialized lease generation'
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    Assert-MO2Test ($releasedAccess.ok -and $releasedAccess.state -eq 'access-released') 'task explicitly releases access when MO2 is no longer needed'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'explicit access release removes the shared lock'

    $abandonedAccess = Invoke-MO2RequestAccess -Config $config -Label 'abandoned task' -RuntimeRoute OCU
    $abandonedAccessId = [string]$abandonedAccess.data.access.accessId
    $ocuRouteProviderMissing = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $abandonedAccessId
    Assert-MO2Test (-not $ocuRouteProviderMissing.ok -and @($ocuRouteProviderMissing.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'fail' }).Count -eq 1) 'OCU route rejects a profile without an enabled OCU provider'
    @('+Skyrim Script Extender for VR (SKSEVR)', '+OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $ocuRouteProviderValid = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $abandonedAccessId
    Assert-MO2Test ($ocuRouteProviderValid.ok -and @($ocuRouteProviderValid.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'pass' }).Count -eq 1) 'OCU route requires and accepts exactly one qualified profile-local OCU provider'
    @('+Skyrim Script Extender for VR (SKSEVR)', '+OpenComposite Runtime Provider', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $contradictoryProvider = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $abandonedAccessId
    Assert-MO2Test (-not $contradictoryProvider.ok -and @($contradictoryProvider.data.runtimeProviders.errors | Where-Object { $_ -match 'repeated or contradicted' }).Count -eq 1) 'runtime-provider discovery rejects duplicate or contradictory markers for one physical mod'
    $aliasProvider = Join-Path $modsRoot 'OpenComposite Runtime Provider Alias'
    New-Item -ItemType Directory -Path (Join-Path $aliasProvider 'root') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $aliasProvider 'root\openvr_api.dll') -Force | Out-Null
    foreach ($markers in @(@('+', '+'), @('-', '-'), @('+', '-'), @('-', '+'))) {
        @(
            '+Skyrim Script Extender for VR (SKSEVR)'
            "$($markers[0])OpenComposite Runtime Provider"
            "$($markers[1])OpenComposite Runtime Provider Alias"
        ) | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
        $aliasResult = & $mo2Module {
            param($fixtureConfig, $markersProfile)
            Get-MO2ProfileRuntimeProviders -Config $fixtureConfig -Profile $markersProfile -IdentityResolver { param($path) 'fixture-physical-id' }
        } $config 'Codex'
        Assert-MO2Test (@($aliasResult.errors | Where-Object { $_ -match 'physical directory is repeated or contradicted' }).Count -eq 1) "runtime-provider identity rejects $($markers -join '/') aliases of one physical directory"
    }
    $physicalIdentityStable = & $mo2Module {
        param($providerPath)
        (Get-MO2DirectoryPhysicalIdentity -Path $providerPath) -ceq
            (Get-MO2DirectoryPhysicalIdentity -Path (Join-Path $providerPath '.'))
    } $ocuMod
    Assert-MO2Test $physicalIdentityStable 'runtime-provider physical identity is stable across lexical path variants'
    $junctionProvider = Join-Path $modsRoot 'OpenComposite Runtime Provider Junction'
    New-Item -ItemType Junction -Path $junctionProvider -Target $ocuMod | Out-Null
    @('+Skyrim Script Extender for VR (SKSEVR)', '+OpenComposite Runtime Provider Junction') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $junctionResult = & $mo2Module { param($fixtureConfig) Get-MO2ProfileRuntimeProviders -Config $fixtureConfig -Profile 'Codex' } $config
    Assert-MO2Test (@($junctionResult.errors | Where-Object { $_ -match 'must not be reparse points' }).Count -eq 1) 'runtime-provider discovery rejects a reparse-point provider before identity admission'
    @('+Skyrim Script Extender for VR (SKSEVR)', '+OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $canonicalLease = Get-Content -LiteralPath $config.session.lockFile -Raw
    $malformedLease = $canonicalLease | ConvertFrom-Json
    $malformedLease.runtimeRoute.id = 'UnknownRuntime'
    $malformedLease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $unknownRoute = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $abandonedAccessId
    Assert-MO2Test (-not $unknownRoute.ok -and @($unknownRoute.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'fail' -and $_.message -match 'not supported' }).Count -eq 1) 'runtime-route validation rejects an unknown persisted route id'
    $malformedLease = $canonicalLease | ConvertFrom-Json
    $malformedLease.runtimeRoute.requiresSteamVR = $true
    $malformedLease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $contradictoryRoute = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $abandonedAccessId
    Assert-MO2Test (-not $contradictoryRoute.ok -and @($contradictoryRoute.checks | Where-Object { $_.name -eq 'runtime-route-provider' -and $_.status -eq 'fail' -and $_.message -match 'canonical' }).Count -eq 1) 'runtime-route validation rejects contradictory persisted route fields'
    foreach ($routeId in @('OCU', 'SteamVR', 'SteamVRNull')) {
        $routeMatrix = & $mo2Module {
            param($id)
            $canonical = Resolve-MO2RuntimeRouteContract -RuntimeRoute $id
            $accepted = (Resolve-MO2PersistedRuntimeRouteContract -RuntimeRoute $canonical).id -ceq $id
            $caseRejected = $false
            $fieldRejected = $false
            $orderRejected = $false
            try { $bad = $canonical | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $bad.id = $bad.id.ToLowerInvariant(); $null = Resolve-MO2PersistedRuntimeRouteContract $bad } catch { $caseRejected = $true }
            try { $bad = $canonical | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $bad.runtimeFamily = 'drift'; $null = Resolve-MO2PersistedRuntimeRouteContract $bad } catch { $fieldRejected = $true }
            try { $bad = $canonical | ConvertTo-Json -Depth 5 | ConvertFrom-Json; [array]::Reverse($bad.incompatibleWith); $null = Resolve-MO2PersistedRuntimeRouteContract $bad } catch { $orderRejected = $true }
            return $accepted -and $caseRejected -and $fieldRejected -and $orderRejected
        } $routeId
        Assert-MO2Test $routeMatrix "canonical $routeId route contract rejects case, field, and ordered incompatibility drift"
    }
    [IO.File]::WriteAllText($config.session.lockFile, $canonicalLease, [Text.UTF8Encoding]::new($false))
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
    $unconfirmedRecovery = Invoke-MO2RecoverAccess -Config $config -AccessId $abandonedAccessId
    Assert-MO2Test (-not $unconfirmedRecovery.ok -and $unconfirmedRecovery.state -eq 'confirmation-required') 'abandoned access is never inferred from time alone'
    $recoveredAccess = Invoke-MO2RecoverAccess -Config $config -AccessId $abandonedAccessId -ConfirmAbandoned -Label 'fixture confirmed abandoned'
    Assert-MO2Test ($recoveredAccess.ok -and $recoveredAccess.state -eq 'access-recovered') 'confirmed abandoned access can be recovered in proven closed state'

    $currentHostProcess = Get-Process -Id $PID
    $currentHostRecord = [pscustomobject]@{ id = $PID; path = $currentHostProcess.Path; startTime = $currentHostProcess.StartTime.ToUniversalTime().ToString('o') }
    # These lifetime-only fixtures intentionally use this test's live host,
    # not the separate MO2 fixture executable configured by the wider suite.
    $hostOwnerConfig = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $hostOwnerConfig.mo2.executable = $currentHostRecord.path
    [ordered]@{
        contractVersion = 'fixture'; sessionId = 'session-pid-reuse'; status = 'running'; ownerPid = $PID
        processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o'); processPath = $currentHostRecord.path
    } | ConvertTo-Json | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $pidReuseInspection = Invoke-MO2Inspect -Config $config
    Assert-MO2Test (-not $pidReuseInspection.data.sessionLock.ownerRunning -and -not $pidReuseInspection.data.sessionLock.ownerIdentityMatched) 'session ownership rejects a reused PID with a different process start time'
    $pidReuseLaunchAdmission = & $mo2Module {
        param($inspection, $ownerProcessId)
        Get-MO2LaunchResumeDisposition -SessionStatus 'game-stopped' -GameProcesses @() -MO2Processes @([pscustomobject]@{ id = $ownerProcessId }) -OwnerPid $ownerProcessId -OwnerIdentityMatched ([bool]$inspection.data.sessionLock.ownerIdentityMatched)
    } $pidReuseInspection $PID
    Assert-MO2Test (-not $pidReuseLaunchAdmission.ok -and $pidReuseLaunchAdmission.reason -eq 'owner-identity-mismatch') 'same-PID different-start-time evidence blocks launch admission before dispatch'
    $pidReuseControlAdmission = & $mo2Module {
        param($fixtureConfig, $ownedLock, $processRecord)
        Resolve-MO2OwnedProcessTarget -Config $fixtureConfig -Owned $ownedLock -Processes @($processRecord) -AdoptDetachedOwner
    } $hostOwnerConfig $pidReuseInspection.data.sessionLock $currentHostRecord
    Assert-MO2Test (-not $pidReuseControlAdmission.ok -and $pidReuseControlAdmission.reason -eq 'recorded-owner-start-time-mismatch' -and $pidReuseControlAdmission.identity.expectedStartTime -cne $pidReuseControlAdmission.identity.actualStartTime -and $pidReuseControlAdmission.identity.expectedPath -ceq $pidReuseControlAdmission.identity.actualPath -and @($pidReuseControlAdmission.targets).Count -eq 0) 'complete same-PID and path evidence with a different start time cannot authorize cooperative process control'
    [ordered]@{
        contractVersion = 'fixture'; sessionId = 'session-path-reuse'; status = 'game-stopped'; ownerPid = $PID
        processStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        processPath = (Join-Path $fixture 'unrelated-process.exe')
    } | ConvertTo-Json | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $pathMismatchInspection = Invoke-MO2Inspect -Config $config
    Assert-MO2Test (-not $pathMismatchInspection.data.sessionLock.ownerIdentityMatched -and $pathMismatchInspection.data.sessionLock.ownerStartTimeMatched -and -not $pathMismatchInspection.data.sessionLock.ownerPathMatched) 'session ownership requires the recorded executable path as well as PID and start time'
    $pathMismatchControlAdmission = & $mo2Module {
        param($fixtureConfig, $ownedLock, $processRecord)
        Resolve-MO2OwnedProcessTarget -Config $fixtureConfig -Owned $ownedLock -Processes @($processRecord) -AdoptDetachedOwner
    } $hostOwnerConfig $pathMismatchInspection.data.sessionLock $currentHostRecord
    Assert-MO2Test (-not $pathMismatchControlAdmission.ok -and $pathMismatchControlAdmission.reason -eq 'recorded-owner-path-mismatch' -and $pathMismatchControlAdmission.identity.expectedPath -cne $pathMismatchControlAdmission.identity.actualPath -and @($pathMismatchControlAdmission.targets).Count -eq 0) 'same-PID same-start but wrong-path evidence blocks cooperative close and stop targets'
    [ordered]@{
        contractVersion = 'fixture'; sessionId = 'session-legacy-owner'; status = 'game-stopped'; ownerPid = $PID
    } | ConvertTo-Json | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $legacyOwnerInspection = Invoke-MO2Inspect -Config $config
    Assert-MO2Test (-not $legacyOwnerInspection.data.sessionLock.ownerIdentityEvidenceComplete -and -not $legacyOwnerInspection.data.sessionLock.ownerIdentityMatched) 'a legacy PID-only lock remains readable but cannot authorize live-process reuse'
    $legacyControlAdmission = & $mo2Module {
        param($fixtureConfig, $ownedLock, $processRecord)
        Resolve-MO2OwnedProcessTarget -Config $fixtureConfig -Owned $ownedLock -Processes @($processRecord) -AdoptDetachedOwner
    } $hostOwnerConfig $legacyOwnerInspection.data.sessionLock $currentHostRecord
    Assert-MO2Test (-not $legacyControlAdmission.ok -and $legacyControlAdmission.reason -eq 'recorded-owner-identity-unbound' -and @($legacyControlAdmission.targets).Count -eq 0) 'legacy incomplete lifetime evidence cannot authorize cooperative process control'
    [ordered]@{
        contractVersion = 'fixture'; sessionId = 'session-qualified-owner'; status = 'game-stopped'; ownerPid = $PID
        processStartTime = $currentHostRecord.startTime; processPath = $currentHostRecord.path
    } | ConvertTo-Json | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $qualifiedOwnerInspection = Invoke-MO2Inspect -Config $config
    $qualifiedControlAdmission = & $mo2Module {
        param($fixtureConfig, $ownedLock, $processRecord)
        Resolve-MO2OwnedProcessTarget -Config $fixtureConfig -Owned $ownedLock -Processes @($processRecord) -AdoptDetachedOwner
    } $hostOwnerConfig $qualifiedOwnerInspection.data.sessionLock $currentHostRecord
    Assert-MO2Test ($qualifiedControlAdmission.ok -and $qualifiedControlAdmission.reason -eq 'recorded-owner' -and @($qualifiedControlAdmission.targets).Count -eq 1) 'complete matching PID, start-time, and path evidence admits the exact retained owner'
    Remove-Item -LiteralPath $config.session.lockFile -Force

    $missingPrepareAccess = Invoke-MO2Prepare -Config $config -Label 'fixture test' -RequireSKSE -WhatIf
    Assert-MO2Test (-not $missingPrepareAccess.ok -and $missingPrepareAccess.state -eq 'missing-access-id') 'prepare rejects a missing explicit access lease without side effects'

    foreach ($routeId in @('OCU', 'SteamVR', 'SteamVRNull')) {
        $providerMarker = if ($routeId -eq 'OCU') { '+OpenComposite Runtime Provider' } else { '-OpenComposite Runtime Provider' }
        @('+Skyrim Script Extender for VR (SKSEVR)', $providerMarker) | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8
        $routeAccess = Invoke-MO2RequestAccess -Config $config -Label "fixture $routeId route" -RuntimeRoute $routeId
        $routeAccessId = [string]$routeAccess.data.access.accessId
        $routePrepared = Invoke-MO2Prepare -Config $config -Label "fixture $routeId route" -RequireSKSE -AccessId $routeAccessId
        $routeLaunch = if ($routePrepared.ok) { Invoke-MO2Launch -Config $config -SessionId ([string]$routePrepared.data.session.sessionId) -WhatIf } else { $null }
        Assert-MO2Test ($routePrepared.ok -and $routePrepared.data.session.runtimeRoute.id -eq $routeId -and $routeLaunch.ok -and $routeLaunch.state -eq 'dry-run') "full prepare and launch admission preserves the canonical $routeId route"
        if ($routePrepared.ok) {
            $null = Invoke-MO2Release -Config $config -SessionId ([string]$routePrepared.data.session.sessionId)
        }
        $null = Invoke-MO2ReleaseAccess -Config $config -AccessId $routeAccessId
    }
    @('+Skyrim Script Extender for VR (SKSEVR)', '-OpenComposite Runtime Provider') | Set-Content -LiteralPath (Join-Path $profile 'modlist.txt') -Encoding utf8

    $sessionAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture session' -RuntimeRoute SteamVR
    $sessionAccessId = [string]$sessionAccess.data.access.accessId
    $prepareDryRun = Invoke-MO2Prepare -Config $config -Label 'fixture test' -RequireSKSE -AccessId $sessionAccessId -WhatIf
    Assert-MO2Test ($prepareDryRun.ok -and $prepareDryRun.state -eq 'dry-run') 'prepare dry-run succeeds'
    $dryRunLease = Invoke-MO2AccessStatus -Config $config -AccessId $sessionAccessId
    Assert-MO2Test ($dryRunLease.state -eq 'access-owned' -and [string]::IsNullOrWhiteSpace([string]$dryRunLease.data.access.sessionId)) 'prepare dry-run leaves the access-only lease unbound'
    Assert-MO2Test (-not (Test-Path -LiteralPath $prepareDryRun.data.sessionPath -PathType Container)) 'prepare dry-run creates no evidence directory'

    $validatedRouteSnapshot = Invoke-MO2Validate -Config $config -RequireClosed -RequireRuntimeRoute -OwnedAccessId $sessionAccessId
    $routeBeforeValidationDrift = & $mo2Module { param($validationResult) Resolve-MO2PersistedRuntimeRouteContract $validationResult.data.sessionLock.data.runtimeRoute } $validatedRouteSnapshot
    $driftedBeforeCapture = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $driftedBeforeCapture.runtimeRoute = & $mo2Module { Resolve-MO2RuntimeRouteContract -RuntimeRoute OCU }
    $driftedBeforeCapture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $validationSnapshotAdmission = & $mo2Module {
        param($fixtureConfig, $fixtureAccessId, $validationResult)
        Get-MO2PrepareRouteAdmission -Validation $validationResult -AccessLock (Get-MO2OwnedAccessLease -Config $fixtureConfig -AccessId $fixtureAccessId)
    } $config $sessionAccessId $validatedRouteSnapshot
    Assert-MO2Test (-not $validationSnapshotAdmission.matched -and $validationSnapshotAdmission.validatedRuntimeRoute.id -eq 'SteamVR' -and $validationSnapshotAdmission.currentRuntimeRoute.id -eq 'OCU') 'prepare route admission detects drift from the exact validation snapshot before artifact creation'
    $driftedBeforeCapture = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $driftedBeforeCapture.runtimeRoute = $routeBeforeValidationDrift
    $driftedBeforeCapture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8

    $moduleSource = [IO.File]::ReadAllText((Join-Path $packageRoot 'MO2Control.psm1'))
    $prepareSource = [regex]::Match($moduleSource, '(?s)function Invoke-MO2Prepare \{.*?\n\}').Value
    $routeAdmissionSource = [regex]::Match($moduleSource, '(?s)function Get-MO2PrepareRouteAdmission \{.*?\n\}').Value
    $validatedSnapshotIndex = $routeAdmissionSource.IndexOf('$Validation.data.sessionLock.data.runtimeRoute', [StringComparison]::Ordinal)
    $currentLeaseIndex = $routeAdmissionSource.IndexOf('$AccessLock.data.runtimeRoute', [StringComparison]::Ordinal)
    Assert-MO2Test ($prepareSource -match 'Get-MO2PrepareRouteAdmission -Validation \$validation -AccessLock \$accessLock' -and $validatedSnapshotIndex -ge 0 -and $currentLeaseIndex -gt $validatedSnapshotIndex) 'prepare derives admission from the validated route snapshot before comparing the second lease read'

    $routeBeforeDrift = & $mo2Module { Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVR }
    $driftedLease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $driftedLease.runtimeRoute = & $mo2Module { Resolve-MO2RuntimeRouteContract -RuntimeRoute OCU }
    $driftedLease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $routeDriftRejected = $false
    try {
        & $mo2Module {
            param($fixtureConfig, $fixtureAccessId, $expectedRoute)
            Bind-MO2PreparedAccessLease -Config $fixtureConfig -AccessId $fixtureAccessId -LockPath ([string]$fixtureConfig.session.lockFile) -PreparedLock ([pscustomobject]@{}) -ExpectedRuntimeRoute $expectedRoute -ExpectedRuntimeRouteFingerprint (Get-MO2RuntimeRouteContractFingerprint $expectedRoute)
        } $config $sessionAccessId $routeBeforeDrift
    }
    catch { $routeDriftRejected = $_.Exception.Message -match 'runtime route changed before session binding' }
    Assert-MO2Test $routeDriftRejected 'prepare revalidates the complete access runtime route inside the final serialized bind'
    $driftedLease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $driftedLease.runtimeRoute = $routeBeforeDrift
    $driftedLease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8

    $prepared = Invoke-MO2Prepare -Config $config -Label 'fixture test' -RequireSKSE -AccessId $sessionAccessId
    Assert-MO2Test ($prepared.ok -and $prepared.state -eq 'prepared') 'prepare creates an owned session'
    if (-not $prepared.ok) { throw "Fixture prepare failed after route-drift recovery: $($prepared | ConvertTo-Json -Depth 12 -Compress)" }
    Assert-MO2Test (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf) 'prepare creates the single-owner lock'
    Assert-MO2Test (Test-Path -LiteralPath (Join-Path $prepared.data.sessionPath 'session.json') -PathType Leaf) 'prepare creates a durable session manifest'
    Assert-MO2Test ([bool]$prepared.data.session.requirements.skseLoader) 'prepare persists the SKSE requirement for launch revalidation'
    Assert-MO2Test (Test-Path -LiteralPath $prepared.data.controllerPath -PathType Leaf) 'prepare snapshots a durable session controller outside the plugin cache'
    Assert-MO2Test (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $prepared.data.controllerPath) 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1') -PathType Leaf) 'durable session controller retains its shader-cache provider verifier'
    Assert-MO2Test (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $prepared.data.controllerPath) 'shader-cache-control\ShaderCacheInventory.ps1') -PathType Leaf) 'durable session controller retains the shader-cache inventory dependency'
    $atomicManifestPath = Join-Path $prepared.data.sessionPath 'session.json'
    $atomicLockBefore = Get-Content -LiteralPath $config.session.lockFile -Raw
    $atomicManifestBefore = Get-Content -LiteralPath $atomicManifestPath -Raw
    try {
        $atomicOwned = & $mo2Module { param($cfg, $sessionId) Get-MO2OwnedSession -Config $cfg -SessionId $sessionId } $config ([string]$prepared.data.session.sessionId)
        $atomicOwnerProcess = Get-Process -Id $PID -ErrorAction Stop
        $atomicConfig = $config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $atomicConfig.mo2.executable = [IO.Path]::GetFullPath([string]$atomicOwnerProcess.Path)
        $atomicConfig.mo2.processNames = @([string]$atomicOwnerProcess.ProcessName)
        $atomicOwnerRecord = [pscustomobject]@{ id = [int]$atomicOwnerProcess.Id; name = [string]$atomicOwnerProcess.ProcessName; path = [IO.Path]::GetFullPath([string]$atomicOwnerProcess.Path); startTime = $atomicOwnerProcess.StartTime.ToUniversalTime().ToString('o') }
        $null = & $mo2Module { param($owned, $owner) Set-MO2OwnedSessionOwner -Owned $owned -ProcessRecord $owner -Reason 'test-owned exact MO2 owner' } $atomicOwned $atomicOwnerRecord
        $atomicStaleOwned = $atomicOwned | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $ownerGuardLockBefore = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $changedAtomicOwner = [pscustomobject]@{ id = [int]$atomicOwnerRecord.id; name = [string]$atomicOwnerRecord.name; path = [string]$atomicOwnerRecord.path; startTime = ([DateTimeOffset]::Parse([string]$atomicOwnerRecord.startTime)).AddSeconds(1).ToString('o') }
        $ownerCommitRejected = $false
        try {
            $null = & $mo2Module { param($cfg, $owned, $process, $changedOwner) $inventory = { @($changedOwner) }.GetNewClosure(); Set-MO2OwnedSessionGameProcesses -Config $cfg -Owned $owned -Processes @($process) -Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc' -OwnerProcessInventoryFactory $inventory } $atomicConfig $atomicOwned $observedGame $changedAtomicOwner
        }
        catch { $ownerCommitRejected = $_.Exception.Message -match 'exact live MO2 owner changed before game-process persistence' }
        $ownerGuardLockAfter = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $ownerGuardGameCount = if ($ownerGuardLockAfter.PSObject.Properties['gameProcesses']) { @($ownerGuardLockAfter.gameProcesses).Count } else { 0 }
        Assert-MO2Test ($ownerCommitRejected -and [long]$ownerGuardLockAfter.generation -eq [long]$ownerGuardLockBefore.generation -and $ownerGuardLockAfter.status -ne 'running' -and $ownerGuardGameCount -eq 0) 'game-process persistence revalidates the exact live MO2 owner inside the serialized transition and refuses an owner replacement without committing'
        $null = & $mo2Module { param($cfg, $owned, $process, $owner) $inventory = { @($owner) }.GetNewClosure(); Set-MO2OwnedSessionGameProcesses -Config $cfg -Owned $owned -Processes @($process) -Status 'running' -TimestampProperty 'gameProcessesAdoptedUtc' -OwnerProcessInventoryFactory $inventory } $atomicConfig $atomicOwned $observedGame $atomicOwnerRecord
        $atomicLock = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $atomicManifest = Get-Content -LiteralPath $atomicManifestPath -Raw | ConvertFrom-Json
        Assert-MO2Test ($atomicLock.status -eq 'running' -and @($atomicLock.gameProcesses).Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$atomicLock.gameProcessesAdoptedUtc)) 'game identity and running state are coherent in the durable ownership record'
        Assert-MO2Test ($atomicManifest.status -eq 'running' -and @($atomicManifest.gameProcesses).Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$atomicManifest.gameProcessesAdoptedUtc) -and [long]$atomicManifest.generation -eq [long]$atomicLock.generation) 'game identity, running state, and generation are coherent in the serialized durable session manifest projection'
        $competingMutationState = [pscustomobject]@{ calls = 0 }
        $competingMutationRejected = $false
        try {
            $null = & $mo2Module { param($fixtureOwned, $state) $action = { param($data) $state.calls++; [pscustomobject]@{ sessionData=$data; result=$true } }.GetNewClosure(); Invoke-MO2OwnedSessionMutation -Owned $fixtureOwned -Action $action } $atomicStaleOwned $competingMutationState
        }
        catch { $competingMutationRejected = $_.Exception.Message -match 'lease transition is stale' }
        $manifestAfterCompetingMutation = Get-Content -LiteralPath $atomicManifestPath -Raw | ConvertFrom-Json
        Assert-MO2Test ($competingMutationRejected -and $competingMutationState.calls -eq 0 -and $manifestAfterCompetingMutation.status -eq 'running' -and [long]$manifestAfterCompetingMutation.generation -eq [long]$atomicLock.generation) 'a competing lifecycle generation refuses before mutation and cannot overtake the newer manifest projection'
        $projectionFailureOwned = & $mo2Module { param($cfg, $sessionId) Get-MO2OwnedSession -Config $cfg -SessionId $sessionId } $config ([string]$prepared.data.session.sessionId)
        $projectionFailureOwned.data.status = 'projection-failure-fixture'
        $projectionFailureReported = $false
        try {
            $null = & $mo2Module { param($owned) $failProjection = { param($data) throw 'injected manifest projection failure' }; Write-MO2OwnedSessionAtomic -Owned $owned -Value $owned.data -ManifestProjectionAction $failProjection } $projectionFailureOwned
        }
        catch { $projectionFailureReported = $_.Exception.Message -match 'ownership lock committed generation' -and $_.Exception.Message -match 'must be reconciled' }
        $lockAfterProjectionFailure = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $manifestAfterProjectionFailure = Get-Content -LiteralPath $atomicManifestPath -Raw | ConvertFrom-Json
        Assert-MO2Test ($projectionFailureReported -and $lockAfterProjectionFailure.status -eq 'projection-failure-fixture' -and [long]$projectionFailureOwned.data.generation -eq [long]$lockAfterProjectionFailure.generation -and $manifestAfterProjectionFailure.status -eq 'running' -and [long]$manifestAfterProjectionFailure.generation -lt [long]$lockAfterProjectionFailure.generation) 'a manifest projection failure is attributable while the authoritative committed generation remains recoverable'
        $projectionRecovery = Invoke-MO2RenewAccess -Config $config -AccessId ([string]$atomicOwned.accessId) -EstimatedMinutes 60
        $lockAfterProjectionRecovery = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $manifestAfterProjectionRecovery = Get-Content -LiteralPath $atomicManifestPath -Raw | ConvertFrom-Json
        Assert-MO2Test ($projectionRecovery.ok -and $manifestAfterProjectionRecovery.status -eq 'projection-failure-fixture' -and [long]$manifestAfterProjectionRecovery.generation -eq [long]$lockAfterProjectionRecovery.generation -and $manifestAfterProjectionRecovery.estimatedDurationMinutes -eq 60) 'the next bound access renewal reconciles a failed manifest projection from the authoritative ownership lock'
    }
    finally {
        $atomicLockBefore | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $atomicManifestBefore | Set-Content -LiteralPath $atomicManifestPath -Encoding utf8
    }
    $durableStatus = & $prepared.data.controllerPath status -SessionId ([string]$prepared.data.session.sessionId) -Compact -NoExit | ConvertFrom-Json
    Assert-MO2Test ($durableStatus.ok -and $durableStatus.state -eq 'prepared') 'durable session controller can resume the owned lifecycle independently'
    Assert-MO2Test ($durableStatus.data.approval.entryPoint -eq [IO.Path]::GetFullPath([string]$prepared.data.controllerPath) -and $durableStatus.data.approval.reusablePrefix[5] -eq 'status') 'durable controller advertises its own stable literal approval prefix'

    $wrongSessionRejected = $false
    try { $null = Invoke-MO2Status -Config $config -SessionId 'wrong-session' } catch { $wrongSessionRejected = $true }
    Assert-MO2Test $wrongSessionRejected 'incorrect session identity is rejected'

    $sessionId = [string]$prepared.data.session.sessionId
    $status = Invoke-MO2Status -Config $config -SessionId $sessionId
    Assert-MO2Test ($status.ok -and $status.state -eq 'prepared') 'owned session status succeeds'

    $missingSession = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') open -ConfigPath $configPath -NoExit | ConvertFrom-Json)
    Assert-MO2Test (-not $missingSession.ok -and $missingSession.state -eq 'missing-session-id' -and $missingSession.data.requiredParameter -eq 'SessionId') 'entry point returns a structured missing-session precondition'
    $forcedMissingSession = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') terminate -ConfigPath $configPath -NoExit | ConvertFrom-Json)
    Assert-MO2Test (-not $forcedMissingSession.data.approval.reusableApprovalEligible -and -not [string]::IsNullOrWhiteSpace([string]$forcedMissingSession.data.approval.oneShotReason)) 'forced termination remains explicitly one-shot even on a precondition failure'
    $missingAccess = (& (Join-Path $packageRoot 'Invoke-MO2Control.ps1') release-access -ConfigPath $configPath -NoExit | ConvertFrom-Json)
    Assert-MO2Test (-not $missingAccess.ok -and $missingAccess.state -eq 'missing-access-id' -and $missingAccess.data.requiredParameter -eq 'AccessId') 'entry point returns a structured missing-access precondition'

    $launchDryRun = Invoke-MO2Launch -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($launchDryRun.ok -and $launchDryRun.state -eq 'dry-run' -and $launchDryRun.data.startOnly) 'launch start-only dry-run succeeds'
    Assert-MO2Test (($launchDryRun.data.arguments -join '|') -eq '--profile|Codex|run|--executable|Launch MGO - Do Not Unlock') 'launch uses exact official MO2 profile and executable command'

    $openDryRun = Invoke-MO2Open -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($openDryRun.ok -and $openDryRun.state -eq 'dry-run' -and -not $openDryRun.data.wouldOpenGame -and $openDryRun.data.startOnly) 'open start-only dry-run opens only exact MO2'
    Assert-MO2Test (($openDryRun.data.arguments -join '|') -eq '--profile|Codex') 'open uses exact official MO2 profile command'

    $buildData = Join-Path $rootBuilderData 'BuildData.json'
    '{}' | Set-Content -LiteralPath $buildData -Encoding utf8
    $launchPendingLock = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $launchPendingLock.status = 'launching'
    $launchPendingLock | Add-Member -NotePropertyName launchedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $launchPendingLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $launchPendingStatus = Invoke-MO2Status -Config $config -SessionId $sessionId
    Assert-MO2Test ($launchPendingStatus.state -eq 'launch-pending' -and $launchPendingStatus.data.controller.launchGraceRemainingSeconds -gt 0) 'active BuildData remains bounded launch-pending during process-appearance grace'
    $launchPendingLock = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $launchPendingLock.launchedUtc = [DateTime]::UtcNow.AddSeconds(-31).ToString('o')
    $launchPendingLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $rootBuilderStatus = Invoke-MO2Status -Config $config -SessionId $sessionId
    Assert-MO2Test ($rootBuilderStatus.state -eq 'rootbuilder-recovery-required' -and $rootBuilderStatus.data.controller.activeBuildData.Count -eq 1) 'status classifies a closed stranded RootBuilder transaction'
    $rootBuilderRecovery = Invoke-MO2RecoverRootBuilder -Config $config -SessionId $sessionId -StartOnly -WhatIf
    Assert-MO2Test ($rootBuilderRecovery.ok -and $rootBuilderRecovery.state -eq 'dry-run' -and $rootBuilderRecovery.data.recovery.destructiveCleanup -eq $false) 'RootBuilder recovery is an attributable exact-launch dry-run'
    Remove-Item -LiteralPath $buildData -Force
    $ownedAfterPending = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $ownedAfterPending.status = 'prepared'
    $ownedAfterPending | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8

    $closeDryRun = Invoke-MO2Close -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($closeDryRun.ok -and $closeDryRun.state -eq 'dry-run' -and $closeDryRun.data.alreadyClosed) 'close dry-run is non-mutating when MO2 is already closed'
    $lockAfterCloseDryRun = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    Assert-MO2Test ($lockAfterCloseDryRun.status -eq 'prepared') 'close dry-run does not change owned session state'

    $stopDryRun = Invoke-MO2Stop -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($stopDryRun.ok -and $stopDryRun.state -eq 'dry-run' -and -not $stopDryRun.data.forceTermination) 'stop dry-run is graceful-only'

    $stopGameDryRun = Invoke-MO2StopGame -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($stopGameDryRun.ok -and $stopGameDryRun.state -eq 'dry-run' -and $stopGameDryRun.data.wouldLeaveMO2Running) 'stop-game dry-run preserves MO2 for controlled relaunch'
    $terminateGameWithoutRecordedIdentity = Invoke-MO2TerminateGame -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test (-not $terminateGameWithoutRecordedIdentity.ok -and $terminateGameWithoutRecordedIdentity.state -eq 'blocked') 'terminate-game refuses process-name recovery without launch-recorded identities and a retained MO2 owner'

    $ownerFixtureProcess = $null
    $preTerminateIdentityLock = Get-Content -LiteralPath $config.session.lockFile -Raw
    try {
        $ownerFixtureProcess = Start-Process -FilePath $mo2Exe -ArgumentList '/c', 'ping -n 30 127.0.0.1 > nul' -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 100
        $ownerFixtureProcess.Refresh()
        $exactResumeLock = $preTerminateIdentityLock | ConvertFrom-Json
        $exactResumeLock.status = 'mo2-open'
        $exactResumeLock | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$ownerFixtureProcess.Id) -Force
        $exactResumeLock | Add-Member -NotePropertyName processPath -NotePropertyValue $mo2Exe -Force
        $exactResumeLock | Add-Member -NotePropertyName processStartTime -NotePropertyValue $ownerFixtureProcess.StartTime.ToUniversalTime().ToString('o') -Force
        $exactResumeLock | Add-Member -NotePropertyName gameProcesses -NotePropertyValue @() -Force
        $exactResumeLock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $exactOwnerRecord = [pscustomobject]@{ id = [int]$ownerFixtureProcess.Id; name = $ownerFixtureProcess.ProcessName; path = $mo2Exe; startTime = $ownerFixtureProcess.StartTime.ToUniversalTime().ToString('o') }
        $staleCloseOwned = & $mo2Module { param($fixtureConfig, $fixtureSessionId) Get-MO2OwnedSession -Config $fixtureConfig -SessionId $fixtureSessionId } $config $sessionId
        $advancedCloseLock = $exactResumeLock | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $advancedCloseLock.generation = [long]$advancedCloseLock.generation + 1L
        $advancedCloseLock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $exactCloseInventory = { param($fixtureConfig) @($exactOwnerRecord) }.GetNewClosure()
        $staleCooperativeClose = & $mo2Module { param($fixtureConfig, $owned, $record, $factory) Invoke-MO2CooperativeCloseCore -Config $fixtureConfig -Owned $owned -InitialProcesses @($record) -TimeoutSeconds 1 -ProcessInventoryFactory $factory } $config $staleCloseOwned $exactOwnerRecord $exactCloseInventory
        $ownerFixtureProcess.Refresh()
        Assert-MO2Test (-not $staleCooperativeClose.closed -and $staleCooperativeClose.blockedReason -eq 'stale-session-generation' -and @($staleCooperativeClose.actions).Count -eq 0 -and -not $ownerFixtureProcess.HasExited) 'cooperative close rejects a stale generation at the UI-action boundary without touching the still-exact owner'
        $exactResumeLock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $delayedGameState = [pscustomobject]@{ calls = 0 }
        $delayedGameInspection = {
            param($fixtureConfig, $currentData)
            $delayedGameState.calls++
            $games = if ($delayedGameState.calls -gt 1) { @([pscustomobject]@{ id = 9193; name = 'MO2ControlImpossibleFixtureGame'; path = $fixtureGame; startTime = [DateTimeOffset]::UtcNow.ToString('o') }) } else { @() }
            [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @($exactOwnerRecord); game = $games }; rootBuilder = [pscustomobject]@{ active = @() } }
        }.GetNewClosure()
        $delayedGameTerminate = & $mo2Module { param($fixtureConfig, $fixtureSessionId, $factory) Invoke-MO2Terminate -Config $fixtureConfig -SessionId $fixtureSessionId -InspectionFactory $factory } $config $sessionId $delayedGameInspection
        $ownerFixtureProcess.Refresh()
        Assert-MO2Test (-not $delayedGameTerminate.ok -and $delayedGameTerminate.data.forceTermination.reason -eq 'game-or-loader-became-active' -and -not $ownerFixtureProcess.HasExited) 'force termination rechecks the no-game veto inside the serialized mutation before touching the exact owner'
        $delayedBuildState = [pscustomobject]@{ calls = 0 }
        $delayedBuildInspection = {
            param($fixtureConfig, $currentData)
            $delayedBuildState.calls++
            $active = if ($delayedBuildState.calls -gt 1) { @([pscustomobject]@{ path = (Join-Path $fixture 'delayed-rootbuilder/BuildData.json') }) } else { @() }
            [pscustomobject]@{ processes = [pscustomobject]@{ mo2 = @($exactOwnerRecord); game = @() }; rootBuilder = [pscustomobject]@{ active = $active } }
        }.GetNewClosure()
        $delayedBuildTerminate = & $mo2Module { param($fixtureConfig, $fixtureSessionId, $factory) Invoke-MO2Terminate -Config $fixtureConfig -SessionId $fixtureSessionId -InspectionFactory $factory } $config $sessionId $delayedBuildInspection
        $ownerFixtureProcess.Refresh()
        Assert-MO2Test (-not $delayedBuildTerminate.ok -and $delayedBuildTerminate.data.forceTermination.reason -eq 'rootbuilder-builddata-became-active' -and -not $ownerFixtureProcess.HasExited) 'force termination rechecks active RootBuilder evidence inside the serialized mutation before touching the exact owner'
        $exactResumeDryRun = Invoke-MO2Launch -Config $config -SessionId $sessionId -StartOnly -WhatIf
        Assert-MO2Test ($exactResumeDryRun.ok -and $exactResumeDryRun.state -eq 'dry-run' -and $exactResumeDryRun.data.ownershipResolution.ok) 'retained launch dry-run requires and accepts the current exact MO2 owner tuple'
        $reusedPidLock = $preTerminateIdentityLock | ConvertFrom-Json
        $reusedPidLock.status = 'mo2-open'
        $reusedPidLock | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$ownerFixtureProcess.Id) -Force
        $reusedPidLock | Add-Member -NotePropertyName processPath -NotePropertyValue $mo2Exe -Force
        $reusedPidLock | Add-Member -NotePropertyName processStartTime -NotePropertyValue ([DateTimeOffset]$ownerFixtureProcess.StartTime.AddMinutes(-1)).ToString('o') -Force
        $reusedPidLock | Add-Member -NotePropertyName gameProcesses -NotePropertyValue @() -Force
        $reusedPidLock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $reusedPidLaunch = Invoke-MO2Launch -Config $config -SessionId $sessionId -StartOnly -WhatIf
        $reusedLaunchReason = if ($reusedPidLaunch.data -is [Collections.IDictionary] -and $reusedPidLaunch.data.Contains('ownershipResolution')) { [string]$reusedPidLaunch.data.ownershipResolution.reason } elseif ($reusedPidLaunch.data -is [Collections.IDictionary] -and $reusedPidLaunch.data.Contains('resumeDisposition')) { [string]$reusedPidLaunch.data.resumeDisposition.reason } else { '' }
        Assert-MO2Test (-not $reusedPidLaunch.ok -and $reusedPidLaunch.state -eq 'blocked' -and $reusedLaunchReason -in @('recorded-owner-start-time-mismatch', 'owner-identity-mismatch')) 'retained launch refuses a reused owner PID before dry-run authorization or dispatch'
        $reusedPidTerminate = Invoke-MO2Terminate -Config $config -SessionId $sessionId -WhatIf
        Assert-MO2Test (-not $reusedPidTerminate.ok -and $reusedPidTerminate.state -eq 'blocked' -and $reusedPidTerminate.data.ownerIdentity.reason -eq 'recorded-owner-start-time-mismatch') 'terminate refuses a configured MO2 process whose reused PID does not match the recorded start time'
    }
    finally {
        $preTerminateIdentityLock | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        if ($ownerFixtureProcess -and -not $ownerFixtureProcess.HasExited) {
            Stop-Process -Id $ownerFixtureProcess.Id -Force -ErrorAction SilentlyContinue
            $ownerFixtureProcess.WaitForExit(5000) | Out-Null
        }
    }

    $terminateDryRun = Invoke-MO2Terminate -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($terminateDryRun.ok -and $terminateDryRun.state -eq 'dry-run') 'terminate dry-run succeeds only after game/rootbuilder absence'
    Assert-MO2Test (@($terminateDryRun.errors).Count -eq 0 -and @($terminateDryRun.warnings).Count -eq 0) 'action results omit null warning and error entries'

    $releaseDryRun = Invoke-MO2Release -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($releaseDryRun.ok -and $releaseDryRun.state -eq 'dry-run') 'release dry-run succeeds'
    Assert-MO2Test (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf) 'release dry-run retains lock'
    '{}' | Set-Content -LiteralPath $buildData -Encoding utf8
    $closeWithStrandedBuildData = Invoke-MO2Close -Config $config -SessionId $sessionId
    Assert-MO2Test (-not $closeWithStrandedBuildData.ok -and $closeWithStrandedBuildData.state -eq 'rootbuilder-recovery-required' -and $closeWithStrandedBuildData.data.activeBuildData.Count -eq 1) 'close does not report success for a closed owner with stranded RootBuilder BuildData'
    $releaseWithStrandedBuildData = Invoke-MO2Release -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test (-not $releaseWithStrandedBuildData.ok -and $releaseWithStrandedBuildData.state -eq 'rootbuilder-recovery-required' -and $releaseWithStrandedBuildData.data.activeBuildData.Count -eq 1) 'release retains session ownership while RootBuilder BuildData remains active'
    Remove-Item -LiteralPath $buildData -Force
    $released = Invoke-MO2Release -Config $config -SessionId $sessionId
    Assert-MO2Test ($released.ok -and $released.state -eq 'session-released-access-retained' -and $released.data.sessionRetained) 'release retires the session, retains evidence, and returns the explicit lease to access-only state'
    $releasedSessionAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $sessionAccessId
    Assert-MO2Test ($releasedSessionAccess.ok -and $releasedSessionAccess.state -eq 'access-released') 'the retained explicit session lease releases after session retirement'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'release removes only the owned lock'

    $recoverClosed = Invoke-MO2RecoverClose -Config $config -Label 'fixture recovery' -WhatIf
    Assert-MO2Test ($recoverClosed.ok -and $recoverClosed.state -eq 'already-closed') 'recovery close is idempotent when exact MO2 is absent'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'already-closed recovery creates no lock'

    $recoveryProcess = Start-Process -FilePath $mo2Exe -ArgumentList @('/d', '/c', 'ping -n 30 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
    try {
        $recoveryDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $recoveryInspection = Invoke-MO2Inspect -Config $config
            if (@($recoveryInspection.data.processes.mo2 | Where-Object id -eq $recoveryProcess.Id).Count -eq 1) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $recoveryDeadline)
        $recoverMissingAccess = Invoke-MO2RecoverClose -Config $config -Label 'fixture recovery' -WhatIf
        Assert-MO2Test (-not $recoverMissingAccess.ok -and $recoverMissingAccess.state -eq 'missing-access-id') 'recovery close requires route-qualified access before adopting a running MO2 process'

        $recoveryAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture recovery access' -RuntimeRoute SteamVR -EstimatedMinutes 5
        $recoveryAccessId = [string]$recoveryAccess.data.access.accessId
        $legacyRecoveryLease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
        $recoveryRuntimeRoute = $legacyRecoveryLease.runtimeRoute
        $legacyRecoveryLease.PSObject.Properties.Remove('runtimeRoute')
        $legacyRecoveryLease | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $sessionDirectoryCountBeforeLegacyRecovery = @(Get-ChildItem -LiteralPath $sessionRoot -Directory).Count
        $legacyRecovery = Invoke-MO2RecoverClose -Config $config -AccessId $recoveryAccessId -Label 'fixture legacy recovery lease' -WhatIf
        Assert-MO2Test (-not $legacyRecovery.ok -and $legacyRecovery.state -eq 'runtime-route-upgrade-required' -and $legacyRecovery.errors[0] -match 'request a new access lease') 'recovery close returns an informative blocked result for a legacy route-less access lease'
        Assert-MO2Test (@(Get-ChildItem -LiteralPath $sessionRoot -Directory).Count -eq $sessionDirectoryCountBeforeLegacyRecovery) 'route-less recovery rejection creates no session artifact'
        $legacyRecoveryLease | Add-Member -NotePropertyName runtimeRoute -NotePropertyValue $recoveryRuntimeRoute
        $legacyRecoveryLease | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
        $expectedRecoveryRouteFingerprint = & $mo2Module { param($route) Get-MO2RuntimeRouteContractFingerprint $route } $recoveryAccess.data.access.runtimeRoute
        $recoverWithRoute = & $mo2Module {
            param($fixtureConfig, $fixtureAccessId)
            $originalDesktopCheck = (Get-Command Test-MO2InteractiveDesktop -CommandType Function).ScriptBlock
            $originalCooperativeClose = (Get-Command Invoke-MO2CooperativeClose -CommandType Function).ScriptBlock
            try {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value { $true }
                Set-Item -Path Function:script:Invoke-MO2CooperativeClose -Value {
                    param($Config, $Owned, $InitialProcesses, $EvidenceDirectory, $TimeoutSeconds)
                    foreach ($record in @($InitialProcesses)) {
                        Stop-Process -Id ([int]$record.id) -Force -ErrorAction SilentlyContinue
                    }
                    [pscustomobject][ordered]@{
                        closed = $true
                        initialProcesses = @($InitialProcesses)
                        finalProcesses = @()
                        actions = @('fixture-cooperative-close')
                        remaining = @()
                        forceTermination = $false
                        unrelatedProcessesTouched = @()
                    }
                }
                Invoke-MO2RecoverClose -Config $fixtureConfig -AccessId $fixtureAccessId -Label 'fixture recovery'
            }
            finally {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value $originalDesktopCheck
                Set-Item -Path Function:script:Invoke-MO2CooperativeClose -Value $originalCooperativeClose
            }
        } $config $recoveryAccessId
        Assert-MO2Test ($recoverWithRoute.ok -and $recoverWithRoute.state -eq 'mo2-closed' -and -not $recoverWithRoute.data.close.forceTermination) 'recovery close durably adopts the exact process without force termination'
    }
    finally {
        if (-not $recoveryProcess.HasExited) { $recoveryProcess.Kill($true); $recoveryProcess.WaitForExit(5000) | Out-Null }
    }

    $recoverySessionId = [string]$recoverWithRoute.data.sessionId
    $recoveryManifest = Get-Content -LiteralPath (Join-Path ([string]$recoverWithRoute.data.sessionPath) 'session.json') -Raw | ConvertFrom-Json
    $recoveryBoundLease = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
    $manifestRecoveryRouteFingerprint = & $mo2Module { param($route) Get-MO2RuntimeRouteContractFingerprint $route } $recoveryManifest.runtimeRoute
    $boundRecoveryRouteFingerprint = & $mo2Module { param($route) Get-MO2RuntimeRouteContractFingerprint $route } $recoveryBoundLease.runtimeRoute
    Assert-MO2Test ($recoveryManifest.sessionId -eq $recoverySessionId -and $manifestRecoveryRouteFingerprint -ceq $expectedRecoveryRouteFingerprint -and $recoveryManifest.status -eq 'mo2-closed') 'recovery manifest durably retains the complete canonical route and closed state'
    Assert-MO2Test ($recoveryBoundLease.sessionId -eq $recoverySessionId -and $boundRecoveryRouteFingerprint -ceq $expectedRecoveryRouteFingerprint -and $recoveryBoundLease.accessId -eq $recoveryAccessId) 'recovery binding durably retains matching session, access, and complete route identities'
    Assert-MO2Test ([long]$recoveryManifest.generation -eq [long]$recoveryBoundLease.generation) 'recovery binding projects its authoritative lease generation into the retained manifest before cooperative control'
    '{}' | Set-Content -LiteralPath $buildData -Encoding utf8
    $recoveredRootBuilder = Invoke-MO2RecoverRootBuilder -Config $config -SessionId $recoverySessionId -StartOnly -WhatIf
    Assert-MO2Test ($recoveredRootBuilder.ok -and $recoveredRootBuilder.state -eq 'dry-run' -and $recoveredRootBuilder.data.rootBuilderRecovery -and ($recoveredRootBuilder.data.arguments -join '|') -eq '--profile|Codex|run|--executable|Launch MGO - Do Not Unlock') 'RootBuilder launch admission consumes the persisted recovered-session route'
    Remove-Item -LiteralPath $buildData -Force
    $releasedRecoverySession = Invoke-MO2Release -Config $config -SessionId $recoverySessionId
    Assert-MO2Test ($releasedRecoverySession.ok -and $releasedRecoverySession.state -eq 'session-released-access-retained') 'recovered session releases back to its explicit access lease after consumer admission'

    $recoverClosedWithAccess = Invoke-MO2RecoverClose -Config $config -AccessId $recoveryAccessId -Label 'fixture recovery' -WhatIf
    Assert-MO2Test ($recoverClosedWithAccess.ok -and $recoverClosedWithAccess.state -eq 'already-closed' -and $recoverClosedWithAccess.data.accessRetained) 'recovery close accepts and retains its exact access-only lease'
    $recoveryAccessStatus = Invoke-MO2AccessStatus -Config $config -AccessId $recoveryAccessId
    Assert-MO2Test ($recoveryAccessStatus.ok -and $recoveryAccessStatus.state -eq 'access-owned') 'already-closed recovery leaves the caller-owned access lease intact'
    $releasedRecoveryAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $recoveryAccessId
    Assert-MO2Test ($releasedRecoveryAccess.ok -and $releasedRecoveryAccess.state -eq 'access-released') 'recovery access can be released normally after closed-state proof'

    $driftRecoveryProcess = Start-Process -FilePath $mo2Exe -ArgumentList @('/d', '/c', 'ping -n 30 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
    try {
        $driftRecoveryDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $driftRecoveryInspection = Invoke-MO2Inspect -Config $config
            if (@($driftRecoveryInspection.data.processes.mo2 | Where-Object id -eq $driftRecoveryProcess.Id).Count -eq 1) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $driftRecoveryDeadline)
        $driftRecoveryAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture recovery drift' -RuntimeRoute SteamVR -EstimatedMinutes 5
        $driftRecoveryAccessId = [string]$driftRecoveryAccess.data.access.accessId
        $driftFailure = & $mo2Module {
            param($fixtureConfig, $fixtureAccessId)
            $originalDesktopCheck = (Get-Command Test-MO2InteractiveDesktop -CommandType Function).ScriptBlock
            $originalAccessReader = (Get-Command Get-MO2OwnedAccessLease -CommandType Function).ScriptBlock
            $script:RecoveryAccessReadCount = 0
            $script:RecoveryOriginalAccessReader = $originalAccessReader
            try {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value { $true }
                Set-Item -Path Function:script:Get-MO2OwnedAccessLease -Value {
                    param($Config, $AccessId)
                    $script:RecoveryAccessReadCount++
                    $lease = & $script:RecoveryOriginalAccessReader -Config $Config -AccessId $AccessId
                    if ($script:RecoveryAccessReadCount -ge 2) {
                        $lease.data.runtimeRoute = Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVRNull
                    }
                    return $lease
                }
                try {
                    $null = Invoke-MO2RecoverClose -Config $fixtureConfig -AccessId $fixtureAccessId -Label 'fixture recovery drift'
                    return [pscustomobject]@{ rejected = $false; message = $null }
                }
                catch {
                    return [pscustomobject]@{ rejected = $true; message = $_.Exception.Message }
                }
            }
            finally {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value $originalDesktopCheck
                Set-Item -Path Function:script:Get-MO2OwnedAccessLease -Value $originalAccessReader
                Remove-Variable -Scope Script -Name RecoveryAccessReadCount, RecoveryOriginalAccessReader -ErrorAction SilentlyContinue
            }
        } $config $driftRecoveryAccessId
        $retainedFailurePath = if ($driftFailure.message -match "Evidence is retained at '([^']+)'") { $Matches[1] } else { $null }
        $retainedFailureManifest = if (-not [string]::IsNullOrWhiteSpace($retainedFailurePath) -and (Test-Path -LiteralPath (Join-Path $retainedFailurePath 'session.json') -PathType Leaf)) { Get-Content -LiteralPath (Join-Path $retainedFailurePath 'session.json') -Raw | ConvertFrom-Json } else { $null }
        Assert-MO2Test ($driftFailure.rejected -and $driftFailure.message -match 'runtime route changed before recovery-close binding') 'recovery binding rejects route drift inside the serialized transition'
        Assert-MO2Test ($null -ne $retainedFailureManifest -and $retainedFailureManifest.status -eq 'recovery-closing' -and $retainedFailureManifest.runtimeRoute.id -eq 'SteamVR') 'failed recovery binding reports and retains attributable producer evidence'
    }
    finally {
        if (-not $driftRecoveryProcess.HasExited) { $driftRecoveryProcess.Kill($true); $driftRecoveryProcess.WaitForExit(5000) | Out-Null }
    }
    $driftAccessStatus = Invoke-MO2AccessStatus -Config $config -AccessId $driftRecoveryAccessId
    Assert-MO2Test ($driftAccessStatus.ok -and $driftAccessStatus.state -eq 'access-owned' -and $driftAccessStatus.data.access.runtimeRoute.id -eq 'SteamVR') 'failed recovery binding leaves the original route-qualified access lease unbound'
    $releasedDriftAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $driftRecoveryAccessId
    Assert-MO2Test ($releasedDriftAccess.ok -and $releasedDriftAccess.state -eq 'access-released') 'failed recovery binding access can be released without touching retained evidence'

    $boundRecoveryProcess = Start-Process -FilePath $mo2Exe -ArgumentList @('/d', '/c', 'ping -n 30 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
    try {
        $boundRecoveryDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $boundRecoveryInspection = Invoke-MO2Inspect -Config $config
            if (@($boundRecoveryInspection.data.processes.mo2 | Where-Object id -eq $boundRecoveryProcess.Id).Count -eq 1) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $boundRecoveryDeadline)
        $boundRecoveryAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture recovery competing bind' -RuntimeRoute SteamVR -EstimatedMinutes 5
        $boundRecoveryAccessId = [string]$boundRecoveryAccess.data.access.accessId
        $boundFailure = & $mo2Module {
            param($fixtureConfig, $fixtureAccessId)
            $originalDesktopCheck = (Get-Command Test-MO2InteractiveDesktop -CommandType Function).ScriptBlock
            $originalAccessReader = (Get-Command Get-MO2OwnedAccessLease -CommandType Function).ScriptBlock
            $script:RecoveryAccessReadCount = 0
            $script:RecoveryOriginalAccessReader = $originalAccessReader
            try {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value { $true }
                Set-Item -Path Function:script:Get-MO2OwnedAccessLease -Value {
                    param($Config, $AccessId)
                    $script:RecoveryAccessReadCount++
                    $lease = & $script:RecoveryOriginalAccessReader -Config $Config -AccessId $AccessId
                    if ($script:RecoveryAccessReadCount -ge 2) {
                        $lease.sessionId = 'fixture-competing-session'
                        $lease.data.sessionId = 'fixture-competing-session'
                    }
                    return $lease
                }
                try {
                    $null = Invoke-MO2RecoverClose -Config $fixtureConfig -AccessId $fixtureAccessId -Label 'fixture recovery competing bind'
                    return [pscustomobject]@{ rejected = $false; message = $null }
                }
                catch {
                    return [pscustomobject]@{ rejected = $true; message = $_.Exception.Message }
                }
            }
            finally {
                Set-Item -Path Function:script:Test-MO2InteractiveDesktop -Value $originalDesktopCheck
                Set-Item -Path Function:script:Get-MO2OwnedAccessLease -Value $originalAccessReader
                Remove-Variable -Scope Script -Name RecoveryAccessReadCount, RecoveryOriginalAccessReader -ErrorAction SilentlyContinue
            }
        } $config $boundRecoveryAccessId
        $retainedBoundFailurePath = if ($boundFailure.message -match "Evidence is retained at '([^']+)'") { $Matches[1] } else { $null }
        $retainedBoundFailureManifest = if (-not [string]::IsNullOrWhiteSpace($retainedBoundFailurePath) -and (Test-Path -LiteralPath (Join-Path $retainedBoundFailurePath 'session.json') -PathType Leaf)) { Get-Content -LiteralPath (Join-Path $retainedBoundFailurePath 'session.json') -Raw | ConvertFrom-Json } else { $null }
        Assert-MO2Test ($boundFailure.rejected -and $boundFailure.message -match 'access lease acquired a session before recovery close could bind it') 'recovery binding rejects a competing session acquired inside the serialized transition'
        Assert-MO2Test ($null -ne $retainedBoundFailureManifest -and $retainedBoundFailureManifest.status -eq 'recovery-closing' -and $retainedBoundFailureManifest.runtimeRoute.id -eq 'SteamVR') 'competing-session rejection reports and retains attributable producer evidence'
    }
    finally {
        if (-not $boundRecoveryProcess.HasExited) { $boundRecoveryProcess.Kill($true); $boundRecoveryProcess.WaitForExit(5000) | Out-Null }
    }
    $boundAccessStatus = Invoke-MO2AccessStatus -Config $config -AccessId $boundRecoveryAccessId
    Assert-MO2Test ($boundAccessStatus.ok -and $boundAccessStatus.state -eq 'access-owned' -and [string]::IsNullOrWhiteSpace([string]$boundAccessStatus.data.access.sessionId)) 'competing-session rejection leaves the original access lease unbound'
    $releasedBoundAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $boundRecoveryAccessId
    Assert-MO2Test ($releasedBoundAccess.ok -and $releasedBoundAccess.state -eq 'access-released') 'competing-session rejection access can be released without touching retained evidence'
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
