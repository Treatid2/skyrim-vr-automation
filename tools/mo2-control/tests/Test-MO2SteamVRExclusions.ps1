# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packageRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $packageRoot 'MO2Control.psm1') -Force
$mo2Module = Get-Module MO2Control
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
$runtimeEntries = @('vrserver.exe', 'vrcompositor.exe', 'vrmonitor.exe', 'vrdashboard.exe', 'vrwebhelper.exe')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mo2-steamvr-exclusions-test-' + [guid]::NewGuid().ToString('N'))

function Assert-ExclusionTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $passes.Add($Name) } else { $failures.Add($Name) }
}

function Get-FixtureBytesToken {
    param([string]$Path)
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

function Get-FixtureInventory {
    param([string]$Path)
    return (@(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0}:{1}' -f [IO.Path]::GetRelativePath($Path, $_.FullName), (Get-FixtureBytesToken $_.FullName)
    }) -join "`n")
}

function New-ExclusionFixture {
    param([string]$Name, [string]$Text, [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($false))
    $root = Join-Path $fixtureRoot $Name
    $mo2Root = Join-Path $root 'Organizer With Arbitrary Name'
    $iniPath = Join-Path $mo2Root 'exact-configured-instance.ini'
    $config = [pscustomobject]@{
        contractVersion = '1.0.0'
        machine = 'isolated-fixture'
        mo2 = [pscustomobject]@{
            root = $mo2Root
            executable = Join-Path $mo2Root 'ModOrganizer.exe'
            ini = $iniPath
            profilesDirectory = Join-Path $mo2Root 'profiles'
            modsDirectory = Join-Path $mo2Root 'mods'
            overwriteDirectory = Join-Path $mo2Root 'overwrite'
            logsDirectory = Join-Path $mo2Root 'logs'
            rootBuilderDefinitions = @()
            rootBuilderDataDirectory = Join-Path $mo2Root 'rootbuilder'
            processNames = @('FixtureOrganizer')
            gameProcessNames = @('FixtureGame')
            runtimeProcessNames = @('FixtureRuntime')
        }
        defaults = [pscustomobject]@{ profile = 'Generic Fixture'; executable = 'Fixture Launcher' }
        storage = [pscustomobject]@{ sessionStaging = (Join-Path $root 'staging'); archive = (Join-Path $root 'archive') }
        limits = [pscustomobject]@{
            maxEnumeratedFiles = 100; overwriteWarningFiles = 10; overwriteBlockFiles = 50
            overwriteWarningBytes = 1024; overwriteBlockBytes = 4096
        }
        session = [pscustomobject]@{ lockFile = Join-Path $root 'sessions\active-session.lock.json' }
    }
    foreach ($directory in @($mo2Root, $config.mo2.profilesDirectory, $config.mo2.modsDirectory,
        $config.mo2.overwriteDirectory, $config.mo2.logsDirectory, $config.mo2.rootBuilderDataDirectory,
        $config.storage.sessionStaging, $config.storage.archive, (Split-Path -Parent $config.session.lockFile))) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText($iniPath, $Text, $Encoding)
    [IO.File]::WriteAllText((Join-Path $mo2Root 'ModOrganizer.ini'), '[Settings]' + "`n" + 'executable_blacklist=leave-this-decoy-alone.exe', [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $root 'machine.fixture.json'
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $access = Invoke-MO2RequestAccess -Config $config -Label $Name -TaskId ('fixture-' + $Name) -RuntimeRoute SteamVR -EstimatedMinutes 5
    if (-not $access.ok) { throw "Unable to acquire isolated fixture lease: $Name" }
    return [pscustomobject]@{
        root = $root; config = $config; configPath = $configPath; ini = $iniPath
        accessId = [string]$access.data.access.accessId; encoding = $Encoding
    }
}

function Invoke-FixtureRejectionCheck {
    param($Fixture, [string]$Name, [string]$AccessId = $Fixture.accessId, [string]$ExpectedErrorPattern)
    $before = Get-FixtureInventory $Fixture.root
    $rejected = $false
    $reason = ''
    try {
        $result = Invoke-MO2ConfigureSteamVRExclusions -Config $Fixture.config -AccessId $AccessId
        $rejected = -not $result.ok
        $reason = @($result.errors) -join '; '
    }
    catch { $rejected = $true; $reason = $_.Exception.Message }
    Assert-ExclusionTest $rejected $Name
    Assert-ExclusionTest ((Get-FixtureInventory $Fixture.root) -ceq $before) ($Name + ' leaves fixture byte-identical')
    if ($ExpectedErrorPattern) {
        Assert-ExclusionTest ($reason -match $ExpectedErrorPattern) ($Name + ' is attributed to the expected safety guard')
    }
}

$originalProcessRecords = & $mo2Module { (Get-Item Function:Get-MO2ProcessRecords).ScriptBlock }
try {
    # Mock only observation. These tests never launch, terminate, or interact with any real process.
    & $mo2Module {
        $script:ExclusionFixtureProcesses = @()
        function script:Get-MO2ProcessRecords {
            param([string[]]$Names)
            return @($script:ExclusionFixtureProcesses | Where-Object {
                $candidate = [IO.Path]::GetFileNameWithoutExtension([string]$_.name)
                @($Names | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -ieq $candidate }).Count -gt 0
            })
        }
    }

    $initialText = "; retain comments and arbitrary Unicode: Grüße`r`n[General]`r`nselected_profile=Generic Fixture`r`n[Settings]`r`nexecutable_blacklist=`"chrome.exe;Existing Tool.EXE;VrServer.ExE`"`r`notherSetting=true`r`n[AnotherSection]`r`nexecutable_blacklist=unrelated.exe`r`n"
    $fixture = New-ExclusionFixture 'Renamed-Pack-A' $initialText ([Text.UTF8Encoding]::new($true))
    $other = New-ExclusionFixture 'Different-Pack-B' "[Settings]`nexecutable_blacklist=untouched.exe`n"
    $otherBefore = Get-FixtureInventory $other.root
    $decoy = Join-Path $fixture.config.mo2.root 'ModOrganizer.ini'
    $decoyBefore = Get-FixtureBytesToken $decoy
    $originalBytes = Get-FixtureBytesToken $fixture.ini
    $allBefore = Get-FixtureInventory $fixture.root

    $dryRun = Invoke-MO2ConfigureSteamVRExclusions -Config $fixture.config -AccessId $fixture.accessId -WhatIf
    Assert-ExclusionTest ($dryRun.ok -and $dryRun.state -eq 'dry-run' -and $dryRun.data.wouldChange) 'dry-run reports proposed exact-target change'
    Assert-ExclusionTest ((Get-FixtureInventory $fixture.root) -ceq $allBefore) 'dry-run creates no backups, receipts, or changed bytes'
    Assert-ExclusionTest (@($dryRun.data.addedEntries).Count -eq 4) 'mixed-case existing runtime exclusion is not duplicated'
    Assert-ExclusionTest ([string]$dryRun.data.iniPath -ceq $fixture.ini) 'plan targets configured INI rather than a modlist-name or default-file assumption'

    $configured = Invoke-MO2ConfigureSteamVRExclusions -Config $fixture.config -AccessId $fixture.accessId
    Assert-ExclusionTest ($configured.ok -and $configured.state -eq 'configured') 'explicit owned transaction configures exclusions'
    $expectedText = $initialText.Replace('chrome.exe;Existing Tool.EXE;VrServer.ExE', 'chrome.exe;Existing Tool.EXE;VrServer.ExE;vrcompositor.exe;vrmonitor.exe;vrdashboard.exe;vrwebhelper.exe')
    $expectedBytes = [byte[]]($fixture.encoding.GetPreamble() + $fixture.encoding.GetBytes($expectedText))
    Assert-ExclusionTest ((Get-FixtureBytesToken $fixture.ini) -ceq [Convert]::ToBase64String($expectedBytes)) 'UTF-8 BOM, CRLF, comments, Unicode, case, unrelated key and sections are byte-preserved'
    Assert-ExclusionTest ((Get-FixtureBytesToken $decoy) -ceq $decoyBefore) 'same-installation decoy INI is untouched'
    Assert-ExclusionTest ((Get-FixtureInventory $other.root) -ceq $otherBefore) 'another modlist and its configuration remain untouched'
    Assert-ExclusionTest ((Get-FixtureBytesToken $configured.data.backupPath) -ceq $originalBytes) 'transaction backup exactly preserves original bytes'
    Assert-ExclusionTest ((Get-FileHash -LiteralPath $configured.data.backupPath -Algorithm SHA256).Hash -ieq $configured.data.originalSha256) 'receipt original hash matches exact backup'
    Assert-ExclusionTest ((Get-FileHash -LiteralPath $fixture.ini -Algorithm SHA256).Hash -ieq $configured.data.updatedSha256) 'receipt updated hash matches installed INI'
    Assert-ExclusionTest (Test-Path -LiteralPath $configured.data.receiptPath -PathType Leaf) 'successful change produces a durable receipt'
    $receipt = Get-Content -LiteralPath $configured.data.receiptPath -Raw | ConvertFrom-Json
    Assert-ExclusionTest (($receipt | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($fixture.accessId)) 'durable receipt does not disclose the bearer access credential'
    Assert-ExclusionTest (@(Get-ChildItem -LiteralPath $fixture.config.mo2.root -File | Where-Object Name -match '[.]tmp$').Count -eq 0) 'atomic replacement leaves no temporary INI file'

    $configuredBefore = Get-FixtureInventory $fixture.root
    $unchanged = Invoke-MO2ConfigureSteamVRExclusions -Config $fixture.config -AccessId $fixture.accessId
    Assert-ExclusionTest ($unchanged.ok -and $unchanged.state -eq 'already-configured' -and @($unchanged.data.addedEntries).Count -eq 0) 'repeating configuration is idempotent'
    Assert-ExclusionTest ((Get-FixtureInventory $fixture.root) -ceq $configuredBefore) 'idempotent operation creates no second backup or receipt and rewrites nothing'

    foreach ($encodingCase in @(
        @{ Name = 'UTF8-LF'; Encoding = [Text.UTF8Encoding]::new($false); Newline = "`n" },
        @{ Name = 'UTF16LE-CRLF'; Encoding = [Text.UnicodeEncoding]::new($false, $true); Newline = "`r`n" },
        @{ Name = 'UTF16BE-LF'; Encoding = [Text.UnicodeEncoding]::new($true, $true); Newline = "`n" }
    )) {
        $lineEnding = $encodingCase.Newline
        $original = '[Settings]' + $lineEnding + 'executable_blacklist="custom.exe"' + $lineEnding + 'unicode=雪'
        $encodedFixture = New-ExclusionFixture $encodingCase.Name $original $encodingCase.Encoding
        $encodingResult = Invoke-MO2ConfigureSteamVRExclusions -Config $encodedFixture.config -AccessId $encodedFixture.accessId
        $expected = $original.Replace('custom.exe', 'custom.exe;' + ($runtimeEntries -join ';'))
        $bytes = [byte[]]($encodingCase.Encoding.GetPreamble() + $encodingCase.Encoding.GetBytes($expected))
        Assert-ExclusionTest ($encodingResult.ok -and (Get-FixtureBytesToken $encodedFixture.ini) -ceq [Convert]::ToBase64String($bytes)) ($encodingCase.Name + ' preserves encoding, newline style, and no final newline')
    }

    $empty = New-ExclusionFixture 'Explicit-Empty' "[Settings]`nexecutable_blacklist=`n"
    $emptyResult = Invoke-MO2ConfigureSteamVRExclusions -Config $empty.config -AccessId $empty.accessId
    Assert-ExclusionTest ($emptyResult.ok -and [IO.File]::ReadAllText($empty.ini) -ceq ("[Settings]`nexecutable_blacklist=`"" + ($runtimeEntries -join ';') + "`"`n")) 'explicit-empty blacklist gains only requested entries, not implicit defaults'

    $paddedText = "[Settings]`r`n  executable_blacklist = `"custom.exe; vrserver.exe;vrmonitor.exe ;`"  `r`n"
    $padded = New-ExclusionFixture 'Padded-Entries' $paddedText
    $paddedResult = Invoke-MO2ConfigureSteamVRExclusions -Config $padded.config -AccessId $padded.accessId
    $paddedExpected = $paddedText.Replace('custom.exe; vrserver.exe;vrmonitor.exe ;', 'custom.exe; vrserver.exe;vrmonitor.exe ;' + ($runtimeEntries -join ';'))
    Assert-ExclusionTest ($paddedResult.ok -and @($paddedResult.data.addedEntries).Count -eq 5 -and [IO.File]::ReadAllText($padded.ini) -ceq $paddedExpected) 'whitespace-padded tokens are preserved but not mistaken for effective exclusions'

    foreach ($missing in @(
        @{ Name = 'Absent-Key'; Text = "[General]`nversion=2.5.2`nname=Other Pack`n[Settings]`nother=true`n[Other]`nfoo=bar`n" },
        @{ Name = 'Absent-Settings'; Text = "[General]`nversion=2.5.2`nname=Other Pack`n" }
    )) {
        $missingFixture = New-ExclusionFixture $missing.Name $missing.Text
        $missingResult = Invoke-MO2ConfigureSteamVRExclusions -Config $missingFixture.config -AccessId $missingFixture.accessId
        if (-not $missingResult.ok) {
            $failedPlan = & $mo2Module { param($path) Get-MO2SteamVRExclusionPlan -Path $path } $missingFixture.ini
            throw ($missing.Name + ': ' + ($missingResult.errors -join '; ') + '; proposed text: ' + [Text.Encoding]::UTF8.GetString($failedPlan.updatedBytes))
        }
        $parsed = & $mo2Module { param($path) Read-MO2IniFile -Path $path } $missingFixture.ini
        $tokens = @(([string]$parsed['Settings']['executable_blacklist']).Trim('"') -split ';')
        Assert-ExclusionTest ($missingResult.ok -and @($runtimeEntries | Where-Object { $_ -notin $tokens }).Count -eq 0) ($missing.Name + ' installs all five exclusions')
        Assert-ExclusionTest ('chrome.exe' -in $tokens -and 'firefox.exe' -in $tokens -and $tokens.Count -gt 5) ($missing.Name + ' materializes effective MO2 defaults instead of silently removing them')
        Assert-ExclusionTest (([IO.File]::ReadAllText($missingFixture.ini)).Contains('name=Other Pack')) ($missing.Name + ' retains unrelated settings')
    }

    foreach ($bad in @(
        @{ Name = 'Duplicate-Key'; Text = "[Settings]`nexecutable_blacklist=first.exe`nExecutable_Blacklist=second.exe`n" },
        @{ Name = 'Duplicate-Section'; Text = "[Settings]`nexecutable_blacklist=first.exe`n[Settings]`nother=value`n" },
        @{ Name = 'Ambiguous-ByteArray'; Text = "[Settings]`nexecutable_blacklist=@ByteArray(custom.exe)`n" },
        @{ Name = 'Absent-Key-Unknown-Version'; Text = "[General]`nversion=99.0.0`n[Settings]`nother=true`n" },
        @{ Name = 'Absent-Key-Unknown-Defaults'; Text = "[General]`nname=Other Pack`n" },
        @{ Name = 'Ambiguous-Comma-List'; Text = "[Settings]`nexecutable_blacklist=first.exe,second.exe`n" },
        @{ Name = 'Unquoted-Semicolon-Comment'; Text = "[Settings]`nexecutable_blacklist=first.exe;commented-not-active.exe`n" },
        @{ Name = 'Encoded-Settings-Alias'; Text = "[General]`nversion=2.5.2`n[%53ettings]`nexecutable_blacklist=hidden.exe`n[Settings]`nexecutable_blacklist=visible.exe`n" },
        @{ Name = 'Encoded-Key-Alias'; Text = "[Settings]`nex%65cutable_blacklist=hidden.exe`nexecutable_blacklist=visible.exe`n" }
    )) {
        $badFixture = New-ExclusionFixture $bad.Name $bad.Text
        $expectedReason = if ($bad.Name -eq 'Unquoted-Semicolon-Comment') { 'semicolon|QSettings|serialization|comment' } else { $null }
        Invoke-FixtureRejectionCheck $badFixture ($bad.Name + ' is rejected without guessing') -ExpectedErrorPattern $expectedReason
    }

    $inspectionFixture = New-ExclusionFixture 'Inspection-Unknown-Defaults' "[General]`nname=Other Pack`n"
    $statusDidNotThrow = $true
    try { $null = & $mo2Module { param($path) Get-MO2SteamVRExclusionStatus -Path $path } $inspectionFixture.ini }
    catch { $statusDidNotThrow = $false }
    Assert-ExclusionTest $statusDidNotThrow 'read-only exclusion status reports unsupported defaults without throwing into inspection'

    foreach ($invalidEncoding in @(
        @{ Name = 'Invalid-UTF8'; Bytes = [byte[]]@(0xC3, 0x28) },
        @{ Name = 'Invalid-UTF16LE'; Bytes = [byte[]]@(0xFF, 0xFE, 0x00, 0xD8) },
        @{ Name = 'Unsupported-UTF32'; Bytes = [byte[]]@(0xFF, 0xFE, 0x00, 0x00, 0x5B, 0x00, 0x00, 0x00) },
        @{ Name = 'Unsupported-UTF7'; Bytes = [byte[]]@(0x2B, 0x2F, 0x76, 0x38, 0x2D, 0x5B, 0x53, 0x65, 0x74, 0x74, 0x69, 0x6E, 0x67, 0x73, 0x5D) },
        @{ Name = 'NUL-Containing'; Bytes = [byte[]]@(0x5B, 0x00, 0x5D) }
    )) {
        $encodingFixture = New-ExclusionFixture $invalidEncoding.Name "[Settings]`nexecutable_blacklist=custom.exe`n"
        [IO.File]::WriteAllBytes($encodingFixture.ini, $invalidEncoding.Bytes)
        Invoke-FixtureRejectionCheck $encodingFixture ($invalidEncoding.Name + ' rejects lossy or ambiguous decoding') -ExpectedErrorPattern 'encoding|UTF|NUL'
    }

    $noLease = New-ExclusionFixture 'Missing-Lease' "[Settings]`nexecutable_blacklist=custom.exe`n"
    Remove-Item -LiteralPath $noLease.config.session.lockFile -Force
    Invoke-FixtureRejectionCheck $noLease 'missing access lease blocks writes'
    $wrongLease = New-ExclusionFixture 'Wrong-Lease' "[Settings]`nexecutable_blacklist=custom.exe`n"
    Invoke-FixtureRejectionCheck $wrongLease 'wrong access credential blocks writes' 'wrong-credential'
    $sessionLease = New-ExclusionFixture 'Session-Bound-Lease' "[Settings]`nexecutable_blacklist=custom.exe`n"
    $lease = Get-Content -LiteralPath $sessionLease.config.session.lockFile -Raw | ConvertFrom-Json
    $lease.sessionId = 'fixture-already-active-session'
    $lease.sessionPath = Join-Path $sessionLease.config.storage.sessionStaging $lease.sessionId
    [IO.File]::WriteAllText($sessionLease.config.session.lockFile, ($lease | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Invoke-FixtureRejectionCheck $sessionLease 'session-bound access lease blocks configuration changes'

    foreach ($processName in @('FixtureOrganizer', 'ModOrganizer', 'FixtureGame', 'FixtureRuntime', 'vrserver', 'vrcompositor', 'vrmonitor', 'vrdashboard', 'vrwebhelper', 'vrstartup')) {
        $busyFixture = New-ExclusionFixture ('Busy-' + $processName) "[Settings]`nexecutable_blacklist=custom.exe`n"
        & $mo2Module { param($name) $script:ExclusionFixtureProcesses = @([pscustomobject]@{ name = $name; id = 424242; path = 'X:\fixture-only\process.exe'; startTime = '2026-01-01T00:00:00Z' }) } $processName
        Invoke-FixtureRejectionCheck $busyFixture ("active $processName blocks writes, including helper-only runtime residue")
        & $mo2Module { $script:ExclusionFixtureProcesses = @() }
    }

    $processHelper = & $mo2Module { (Get-Item Function:Get-MO2SteamVRExclusionProcesses).ScriptBlock }
    $raceFixture = New-ExclusionFixture 'External-Edit-Race' "[Settings]`nexecutable_blacklist=custom.exe`n"
    $raceOriginal = Get-FixtureBytesToken $raceFixture.ini
    $externalText = "[Settings]`nexecutable_blacklist=external-editor.exe`n"
    try {
        & $mo2Module {
            param($path, $externalText)
            $script:ExclusionFixtureProcessCalls = 0
            $script:ExclusionFixtureRacePath = $path
            $script:ExclusionFixtureRaceText = $externalText
            function script:Get-MO2SteamVRExclusionProcesses {
                param($Config)
                $script:ExclusionFixtureProcessCalls++
                if ($script:ExclusionFixtureProcessCalls -eq 2) {
                    [IO.File]::WriteAllText($script:ExclusionFixtureRacePath, $script:ExclusionFixtureRaceText, [Text.UTF8Encoding]::new($false))
                }
                return [pscustomobject]@{ mo2 = @(); game = @(); steamVr = @() }
            }
        } $raceFixture.ini $externalText
        $raceResult = Invoke-MO2ConfigureSteamVRExclusions -Config $raceFixture.config -AccessId $raceFixture.accessId
        Assert-ExclusionTest (-not $raceResult.ok -and $raceResult.state -eq 'failed-unchanged') 'concurrent external INI edit refuses replacement'
        Assert-ExclusionTest ([IO.File]::ReadAllText($raceFixture.ini) -ceq $externalText) 'concurrent external edit is not overwritten or rolled back'
        Assert-ExclusionTest ((Get-FixtureBytesToken $raceResult.data.backupPath) -ceq $raceOriginal -and (Test-Path -LiteralPath $raceResult.data.receiptPath)) 'external-edit rejection retains original backup and durable failure receipt'
    }
    finally {
        & $mo2Module { param($implementation) Set-Item Function:script:Get-MO2SteamVRExclusionProcesses $implementation } $processHelper
    }

    $restartFixture = New-ExclusionFixture 'Runtime-Start-Race' "[Settings]`nexecutable_blacklist=custom.exe`n"
    $restartOriginal = Get-FixtureBytesToken $restartFixture.ini
    try {
        & $mo2Module {
            $script:ExclusionFixtureProcessCalls = 0
            function script:Get-MO2SteamVRExclusionProcesses {
                param($Config)
                $script:ExclusionFixtureProcessCalls++
                $runtime = if ($script:ExclusionFixtureProcessCalls -ge 2) { @([pscustomobject]@{ name = 'vrwebhelper'; id = 424243 }) } else { @() }
                return [pscustomobject]@{ mo2 = @(); game = @(); steamVr = @($runtime) }
            }
        }
        $restartResult = Invoke-MO2ConfigureSteamVRExclusions -Config $restartFixture.config -AccessId $restartFixture.accessId
        Assert-ExclusionTest (-not $restartResult.ok -and $restartResult.state -eq 'failed-unchanged' -and (Get-FixtureBytesToken $restartFixture.ini) -ceq $restartOriginal) 'runtime starting during preparation prevents atomic replacement'
    }
    finally {
        & $mo2Module { param($implementation) Set-Item Function:script:Get-MO2SteamVRExclusionProcesses $implementation } $processHelper
    }

    $planHelper = & $mo2Module { (Get-Item Function:Get-MO2SteamVRExclusionPlan).ScriptBlock }
    $rollbackFixture = New-ExclusionFixture 'Post-Write-Verification-Failure' "[Settings]`nexecutable_blacklist=custom.exe`n"
    $rollbackOriginal = Get-FixtureBytesToken $rollbackFixture.ini
    try {
        & $mo2Module {
            param($implementation)
            $script:ExclusionFixturePlanImplementation = $implementation
            $script:ExclusionFixturePlanCalls = 0
            function script:Get-MO2SteamVRExclusionPlan {
                param([string]$Path)
                $script:ExclusionFixturePlanCalls++
                if ($script:ExclusionFixturePlanCalls -eq 2) { throw 'Injected isolated post-write verification failure.' }
                return & $script:ExclusionFixturePlanImplementation -Path $Path
            }
        } $planHelper
        $rollbackResult = Invoke-MO2ConfigureSteamVRExclusions -Config $rollbackFixture.config -AccessId $rollbackFixture.accessId
        Assert-ExclusionTest (-not $rollbackResult.ok -and $rollbackResult.state -eq 'rolled-back' -and $rollbackResult.data.rollback.restored) 'post-write verification failure triggers verified atomic rollback'
        Assert-ExclusionTest ((Get-FixtureBytesToken $rollbackFixture.ini) -ceq $rollbackOriginal) 'rollback restores original INI byte-for-byte'
        $rollbackReceipt = Get-Content -LiteralPath $rollbackResult.data.receiptPath -Raw | ConvertFrom-Json
        Assert-ExclusionTest ($rollbackReceipt.state -eq 'rolled-back' -and -not $rollbackReceipt.ok) 'durable receipt reports rollback, never successful configuration'
    }
    finally {
        & $mo2Module { param($implementation) Set-Item Function:script:Get-MO2SteamVRExclusionPlan $implementation } $planHelper
    }

    $entrySource = Get-Content -LiteralPath (Join-Path $packageRoot 'Invoke-MO2Control.ps1') -Raw
    Assert-ExclusionTest ($entrySource -match 'configure-steamvr-exclusions' -and $entrySource -match 'Invoke-MO2ConfigureSteamVRExclusions') 'literal entry point exposes the explicit maintenance command'
}
finally {
    & $mo2Module {
        param($implementation)
        Set-Item Function:script:Get-MO2ProcessRecords $implementation
        Remove-Variable ExclusionFixtureProcesses, ExclusionFixtureProcessCalls, ExclusionFixtureRacePath, ExclusionFixtureRaceText, ExclusionFixturePlanImplementation, ExclusionFixturePlanCalls -Scope Script -ErrorAction SilentlyContinue
    } $originalProcessRecords
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedFixture) -notmatch '^mo2-steamvr-exclusions-test-[a-f0-9]{32}$') {
            throw "Refusing to clean unexpected fixture path: $resolvedFixture"
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

[pscustomobject]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; failures = @($failures); tests = @($passes) } | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) { exit 1 }
