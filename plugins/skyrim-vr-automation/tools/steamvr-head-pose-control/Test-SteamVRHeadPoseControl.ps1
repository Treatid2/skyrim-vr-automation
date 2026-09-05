# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1'
$mapName = "Local\CSXVRHeadPose-test-$([guid]::NewGuid().ToString('N'))"
$mapping = $null
$view = $null
$passed = 0
$fixture = Join-Path ([IO.Path]::GetTempPath()) "csx-head-pose-test-$([guid]::NewGuid().ToString('N'))"
$priorInstallControlRoot = $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT
$env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT = Join-Path $fixture 'install-control'

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

try {
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bundleRoot = Join-Path $repositoryRoot 'drivers\codex_head_pose'
    $provenance = Get-Content -LiteralPath (Join-Path $bundleRoot 'build-provenance.json') -Raw | ConvertFrom-Json
    foreach ($artifact in $provenance.artifacts.psobject.Properties) {
        $artifactPath = Join-Path $bundleRoot $artifact.Name
        Assert-Test ((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -eq [string]$artifact.Value) "bundled artifact hash matches provenance: $($artifact.Name)"
    }
    Assert-Test (Test-Path -LiteralPath (Join-Path $bundleRoot 'licenses\OpenVR-LICENSE.txt') -PathType Leaf) 'bundled OpenVR runtime license is present'

    $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($mapName, 128)
    $view = $mapping.CreateViewAccessor(0, 128, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $view.Write(0, [uint32]0x48505343)
    $view.Write(4, [uint16]2)
    $view.Write(6, [uint16]128)
    $view.Write(8, [uint64]2)
    $view.Write(16, [uint64]2)
    $view.Write(24, [uint32]1)
    $view.Write(28, [uint32]1)
    $view.Write(32, [double]0); $view.Write(40, [double]1.68); $view.Write(48, [double]0)
    $view.Write(56, [double]1); $view.Write(64, [double]0); $view.Write(72, [double]0); $view.Write(80, [double]0)
    $view.Write(88, [uint64]101)
    $view.Write(96, [uint64]101)
    $view.Write(104, [uint64]202)
    $view.Write(112, [uint32]$PID)
    $view.Write(120, [uint64][DateTime]::UtcNow.ToFileTimeUtc())
    $view.Flush()

    $inspect = & $entry inspect -MapName $mapName -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($inspect.ok -and $inspect.state -eq 'provider-running' -and $inspect.data.pose.eyeHeightMeters -eq 1.68) 'inspect reads the versioned pose map'

    $qualify = & $entry qualify -MapName $mapName -SkipOpenVRProbe -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $qualify.ok -and $qualify.state -eq 'head-pose-not-qualified' -and $qualify.data.pose.qualified -and $qualify.data.applicationPose.skipped) 'skipping the independent stereo probe remains explicitly unqualified'

    $set = & $entry set -MapName $mapName -EyeHeightMeters 1.72 -YawDegrees 15 -NoWait -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($set.ok -and $set.state -eq 'pose-submitted' -and $set.data.writerNonce -ne 0 -and ($view.ReadUInt64(8) % 2) -eq 0) 'set publishes an atomic even pose sequence with a unique writer nonce'
    Assert-Test ([Math]::Abs($view.ReadDouble(40) - 1.72) -lt 0.000001) 'set writes the requested eye height'

    $view.Write(16, $view.ReadUInt64(8)); $view.Write(96, $view.ReadUInt64(88)); $view.Write(24, [uint32]1); $view.Flush()
    $requalified = & $entry qualify -MapName $mapName -SkipOpenVRProbe -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $requalified.ok -and $requalified.data.pose.qualified -and [Math]::Abs($requalified.data.pose.eyeHeightMeters - 1.72) -lt 0.000001) 'exact nonce acknowledgement requalifies the shared pose while skipped stereo evidence remains unqualified'

    $view.Write(96, [uint64]($view.ReadUInt64(88) + 1)); $view.Flush()
    $wrongNonce = & $entry inspect -MapName $mapName -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongNonce.data.pose.acknowledged -and -not $wrongNonce.data.pose.qualified) 'an acknowledgement for a different writer nonce cannot satisfy the transaction'

    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $writerRuns = @(
        foreach ($height in @(1.73, 1.74)) {
            $stdout = Join-Path $fixture "writer-$height.stdout.json"
            $stderr = Join-Path $fixture "writer-$height.stderr.log"
            $process = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', $entry, 'set', '-MapName', $mapName, '-EyeHeightMeters', [string]$height, '-NoWait', '-Compact', '-NoExit') -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
            [pscustomobject]@{ process = $process; stdout = $stdout; stderr = $stderr }
        }
    )
    foreach ($run in $writerRuns) {
        if (-not $run.process.WaitForExit(10000)) { $run.process.Kill($true); throw 'Concurrent writer test exceeded its bounded deadline.' }
        if ($run.process.ExitCode -ne 0) { throw "Concurrent writer failed: $([IO.File]::ReadAllText($run.stderr))" }
    }
    $writerResults = @($writerRuns | ForEach-Object { [IO.File]::ReadAllText($_.stdout) | ConvertFrom-Json })
    Assert-Test (@($writerResults.data.requestedSequence | Sort-Object -Unique).Count -eq 2 -and @($writerResults.data.writerNonce | Sort-Object -Unique).Count -eq 2) 'concurrent writers serialize to distinct sequences and command nonces'

    $installRoot = Join-Path $fixture 'installed\codex_head_pose'
    $oldDll = Join-Path $installRoot 'bin\win64\driver_codex_head_pose.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $oldDll) -Force | Out-Null
    [IO.File]::WriteAllText($oldDll, 'owned-old-driver', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot '.csx-vr-automation-driver.json'), '{"schemaVersion":1,"driverName":"codex_head_pose"}', [Text.UTF8Encoding]::new($false))
    $oldHash = (Get-FileHash -LiteralPath $oldDll -Algorithm SHA256).Hash
    $openVrPaths = Join-Path $fixture 'openvrpaths.vrpath'
    [ordered]@{ version = 1; external_drivers = @($installRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPaths -Encoding utf8
    $openVrBefore = [IO.File]::ReadAllBytes($openVrPaths)
    $evidence = Join-Path $fixture 'evidence'
    # Fixture transactions must not depend on unrelated live SteamVR state;
    # production process checks remain exercised outside this test scope.
    function Get-Process {
        [CmdletBinding(DefaultParameterSetName = 'Name')]
        param(
            [Parameter(ParameterSetName = 'Name')]
            [string[]]$Name,
            [Parameter(ParameterSetName = 'Id')]
            [int[]]$Id
        )
        $fixtureSteamVrNames = @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup')
        if ($PSCmdlet.ParameterSetName -eq 'Name' -and $Name.Count -gt 0 -and
            @($Name | Where-Object { $_ -notin $fixtureSteamVrNames }).Count -eq 0) {
            return
        }
        return Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    $failedUpgrade = & $entry install -DriverPackagePath $bundleRoot -InstallRoot $installRoot -VRPathRegPath $entry -OpenVRPathsPath $openVrPaths -EvidenceDirectory $evidence -Upgrade -InternalTestFailurePoint install-after-replacement -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedUpgrade.ok -and $failedUpgrade.errors[0] -match 'exact previous install.*restored') 'injected upgrade failure reports verified rollback'
    Assert-Test ((Get-FileHash -LiteralPath $oldDll -Algorithm SHA256).Hash -eq $oldHash) 'upgrade rollback restores the exact original driver DLL'
    Assert-Test ([Convert]::ToHexString([IO.File]::ReadAllBytes($openVrPaths)) -eq [Convert]::ToHexString($openVrBefore)) 'upgrade rollback restores the exact OpenVR registration preimage'
    Assert-Test (@(Get-ChildItem -LiteralPath (Split-Path -Parent $installRoot) -Directory -Filter 'codex_head_pose.uncommitted-*').Count -eq 1) 'upgrade rollback quarantines the uncommitted replacement'

    $installControlDirectory = @(Get-ChildItem -LiteralPath $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT -Directory)[0]
    $installLock = [IO.File]::Open((Join-Path $installControlDirectory.FullName 'target.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $contendedInstall = & $entry install -DriverPackagePath $bundleRoot -InstallRoot $installRoot -VRPathRegPath $entry -OpenVRPathsPath $openVrPaths -EvidenceDirectory $evidence -Upgrade -InstallLockTimeoutMilliseconds 100 -Compact -NoExit | ConvertFrom-Json
        Assert-Test (-not $contendedInstall.ok -and $contendedInstall.errors[0] -match 'installation lock') 'concurrent installers cannot enter the same target and OpenVR registration transaction'
    }
    finally { $installLock.Dispose() }

    $authoritativeJournalPath = Join-Path $installControlDirectory.FullName 'install.journal.json'
    $interrupted = Get-Content -LiteralPath $authoritativeJournalPath -Raw | ConvertFrom-Json -AsHashtable
    $existingQuarantine = [string]$interrupted['quarantine']
    if (Test-Path -LiteralPath $existingQuarantine) { Remove-Item -LiteralPath $existingQuarantine -Recurse -Force }
    Move-Item -LiteralPath $installRoot -Destination ([string]$interrupted['previousInstall'])
    Copy-Item -LiteralPath $bundleRoot -Destination $installRoot -Recurse
    [IO.File]::WriteAllText((Join-Path $installRoot '.csx-vr-automation-driver.json'), '{"schemaVersion":1,"driverName":"codex_head_pose"}', [Text.UTF8Encoding]::new($false))
    $interrupted['phase'] = 'replacement-command-uncommitted'
    $interrupted['failure'] = $null
    $interrupted['rollbackErrors'] = @()
    $interrupted['completedUtc'] = $null
    $interrupted | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $authoritativeJournalPath -Encoding utf8
    $interrupted | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath ([string]$interrupted['evidenceJournalPath']) -Encoding utf8
    $differentEvidence = Join-Path $fixture 'different-evidence'
    New-Item -ItemType Directory -Path $differentEvidence | Out-Null
    $recoveryAttempt = & $entry install -DriverPackagePath (Join-Path $fixture 'missing-package') -InstallRoot $installRoot -VRPathRegPath $entry -OpenVRPathsPath $openVrPaths -EvidenceDirectory $differentEvidence -Upgrade -Compact -NoExit | ConvertFrom-Json
    $recoveredJournal = Get-Content -LiteralPath $authoritativeJournalPath -Raw | ConvertFrom-Json
    Assert-Test (-not $recoveryAttempt.ok -and $recoveryAttempt.errors[0] -match 'Driver package is missing' -and $recoveredJournal.phase -eq 'recovered') 'a later caller recovers an interrupted replacement before validating its new package or evidence directory'
    Assert-Test ((Get-FileHash -LiteralPath $oldDll -Algorithm SHA256).Hash -eq $oldHash -and [Convert]::ToHexString([IO.File]::ReadAllBytes($openVrPaths)) -eq [Convert]::ToHexString($openVrBefore)) 'restart recovery restores exact driver provenance and OpenVR registration bytes'

    $successfulUpgrade = & $entry install -DriverPackagePath $bundleRoot -InstallRoot $installRoot -VRPathRegPath $entry -OpenVRPathsPath $openVrPaths -EvidenceDirectory $differentEvidence -Upgrade -Compact -NoExit | ConvertFrom-Json
    $committedInstall = Get-Content -LiteralPath $authoritativeJournalPath -Raw | ConvertFrom-Json
    Assert-Test ($successfulUpgrade.ok -and $successfulUpgrade.state -eq 'driver-upgraded' -and $committedInstall.phase -eq 'committed') 'recovered target admits one subsequent serialized upgrade and commits its authoritative journal'
    Assert-Test ($successfulUpgrade.data.dllSha256 -eq [string]$provenance.artifacts.'bin/win64/driver_codex_head_pose.dll' -and $successfulUpgrade.data.poseProbeSha256 -eq [string]$provenance.artifacts.'tools/csx_openvr_pose_probe.exe') 'committed upgrade binds installed driver and probe hashes to bundled provenance'

    [pscustomobject]@{ ok = $true; passed = $passed } | ConvertTo-Json -Compress
}
finally {
    $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT = $priorInstallControlRoot
    if ($view) { $view.Dispose() }
    if ($mapping) { $mapping.Dispose() }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
