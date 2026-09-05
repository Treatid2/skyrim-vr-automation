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
    $staging = Join-Path $fixture 'staging'
    $archive = Join-Path $fixture 'archive'
    $sessionRoot = Join-Path $fixture 'sessions'

    foreach ($directory in @($profile, $overwrite, $rootBuilderDefinitions, $rootBuilderData, $gameRoot, $loaderMod, (Join-Path $ocuMod 'root'), (Join-Path $ocuMod 'SKSE\Plugins'), $staging, $archive, $sessionRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $mo2Exe = Join-Path $mo2Root 'ModOrganizer.exe'
    $loader = Join-Path $loaderMod 'sksevr_loader.exe'
    $plainGame = Join-Path $gameRoot 'SkyrimVR.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null
    New-Item -ItemType File -Path $loader -Force | Out-Null
    New-Item -ItemType File -Path $plainGame -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'root\openvr_api.dll') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'root\opencomposite.ini') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $ocuMod 'SKSE\Plugins\OpenCompositeInput.dll') -Force | Out-Null
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
    $staleOwnedSession = & $mo2Module { param($fixtureConfig, $fixtureSessionId) Get-MO2OwnedSession -Config $fixtureConfig -SessionId $fixtureSessionId } $config $explicitSessionId
    $inSessionRenewal = Invoke-MO2RenewAccess -Config $config -AccessId $accessId -EstimatedMinutes 45
    $staleOwnedSession.data.status = 'fixture-stale-writer'
    $null = & $mo2Module { param($fixtureOwned) Write-MO2OwnedSessionAtomic -Owned $fixtureOwned -Value $fixtureOwned.data } $staleOwnedSession
    $postStaleWriteStatus = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    Assert-MO2Test ($inSessionRenewal.ok -and $postStaleWriteStatus.data.access.estimatedDurationMinutes -eq 45 -and [long]$postStaleWriteStatus.data.access.generation -eq 5L -and $postStaleWriteStatus.data.access.runtimeRoute.id -eq 'SteamVRNull') 'a stale session writer preserves a concurrent serialized lease renewal and runtime route'
    $prematureAccessRelease = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    Assert-MO2Test (-not $prematureAccessRelease.ok -and $prematureAccessRelease.state -eq 'session-release-required') 'access cannot be released while a session is bound'
    $explicitReleased = Invoke-MO2Release -Config $config -SessionId $explicitSessionId
    Assert-MO2Test ($explicitReleased.ok -and $explicitReleased.state -eq 'session-released-access-retained' -and $explicitReleased.data.releaseAccessRequired) 'session release retains explicitly requested access'
    $accessOnlyStatus = Invoke-MO2AccessStatus -Config $config -AccessId $accessId
    Assert-MO2Test ($accessOnlyStatus.state -eq 'access-owned' -and $accessOnlyStatus.data.access.state -eq 'access-held' -and [string]::IsNullOrWhiteSpace([string]$accessOnlyStatus.data.access.sessionId)) 'released session returns the lock to access-only state'
    Assert-MO2Test ([long]$accessOnlyStatus.data.access.generation -eq 6L) 'session release advances the serialized lease generation'
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

    [ordered]@{
        contractVersion = 'fixture'; sessionId = 'session-pid-reuse'; status = 'running'; ownerPid = $PID
        processStartTime = [DateTime]::UtcNow.AddDays(-1).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $config.session.lockFile -Encoding utf8
    $pidReuseInspection = Invoke-MO2Inspect -Config $config
    Assert-MO2Test (-not $pidReuseInspection.data.sessionLock.ownerRunning -and -not $pidReuseInspection.data.sessionLock.ownerIdentityMatched) 'session ownership rejects a reused PID with a different process start time'
    Remove-Item -LiteralPath $config.session.lockFile -Force

    $missingPrepareAccess = Invoke-MO2Prepare -Config $config -Label 'fixture test' -RequireSKSE -WhatIf
    Assert-MO2Test (-not $missingPrepareAccess.ok -and $missingPrepareAccess.state -eq 'missing-access-id') 'prepare rejects a missing explicit access lease without side effects'
    $sessionAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture session' -RuntimeRoute SteamVR
    $sessionAccessId = [string]$sessionAccess.data.access.accessId
    $prepareDryRun = Invoke-MO2Prepare -Config $config -Label 'fixture test' -RequireSKSE -AccessId $sessionAccessId -WhatIf
    Assert-MO2Test ($prepareDryRun.ok -and $prepareDryRun.state -eq 'dry-run') 'prepare dry-run succeeds'
    $dryRunLease = Invoke-MO2AccessStatus -Config $config -AccessId $sessionAccessId
    Assert-MO2Test ($dryRunLease.state -eq 'access-owned' -and [string]::IsNullOrWhiteSpace([string]$dryRunLease.data.access.sessionId)) 'prepare dry-run leaves the access-only lease unbound'
    Assert-MO2Test (-not (Test-Path -LiteralPath $prepareDryRun.data.sessionPath -PathType Container)) 'prepare dry-run creates no evidence directory'

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

    $terminateDryRun = Invoke-MO2Terminate -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($terminateDryRun.ok -and $terminateDryRun.state -eq 'dry-run') 'terminate dry-run succeeds only after game/rootbuilder absence'
    Assert-MO2Test (@($terminateDryRun.errors).Count -eq 0 -and @($terminateDryRun.warnings).Count -eq 0) 'action results omit null warning and error entries'

    $releaseDryRun = Invoke-MO2Release -Config $config -SessionId $sessionId -WhatIf
    Assert-MO2Test ($releaseDryRun.ok -and $releaseDryRun.state -eq 'dry-run') 'release dry-run succeeds'
    Assert-MO2Test (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf) 'release dry-run retains lock'
    $released = Invoke-MO2Release -Config $config -SessionId $sessionId
    Assert-MO2Test ($released.ok -and $released.state -eq 'session-released-access-retained' -and $released.data.sessionRetained) 'release retires the session, retains evidence, and returns the explicit lease to access-only state'
    $releasedSessionAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $sessionAccessId
    Assert-MO2Test ($releasedSessionAccess.ok -and $releasedSessionAccess.state -eq 'access-released') 'the retained explicit session lease releases after session retirement'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'release removes only the owned lock'

    $recoverClosed = Invoke-MO2RecoverClose -Config $config -Label 'fixture recovery' -WhatIf
    Assert-MO2Test ($recoverClosed.ok -and $recoverClosed.state -eq 'already-closed') 'recovery close is idempotent when exact MO2 is absent'
    Assert-MO2Test (-not (Test-Path -LiteralPath $config.session.lockFile -PathType Leaf)) 'already-closed recovery creates no lock'

    $recoveryAccess = Invoke-MO2RequestAccess -Config $config -Label 'fixture recovery access' -RuntimeRoute SteamVR -EstimatedMinutes 5
    $recoveryAccessId = [string]$recoveryAccess.data.access.accessId
    $recoverClosedWithAccess = Invoke-MO2RecoverClose -Config $config -AccessId $recoveryAccessId -Label 'fixture recovery' -WhatIf
    Assert-MO2Test ($recoverClosedWithAccess.ok -and $recoverClosedWithAccess.state -eq 'already-closed' -and $recoverClosedWithAccess.data.accessRetained) 'recovery close accepts and retains its exact access-only lease'
    $recoveryAccessStatus = Invoke-MO2AccessStatus -Config $config -AccessId $recoveryAccessId
    Assert-MO2Test ($recoveryAccessStatus.ok -and $recoveryAccessStatus.state -eq 'access-owned') 'already-closed recovery leaves the caller-owned access lease intact'
    $releasedRecoveryAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $recoveryAccessId
    Assert-MO2Test ($releasedRecoveryAccess.ok -and $releasedRecoveryAccess.state -eq 'access-released') 'recovery access can be released normally after closed-state proof'
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
