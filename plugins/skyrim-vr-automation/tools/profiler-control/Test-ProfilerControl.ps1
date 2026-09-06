# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passes = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) }
    else { $failures.Add($Message) }
}

function New-Timer([string]$Name, [double]$GpuMs) {
    [pscustomobject][ordered]@{
        name = $Name
        activeGpu = $true
        hasGpu = $true
        gpuMs = $GpuMs
        topLevelMs = $GpuMs
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('csx-profiler-control-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the temporary directory: $resolvedTestRoot"
}

try {
    New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
    $stateAPath = Join-Path $resolvedTestRoot 'state-a.raw.json'
    $stateBPath = Join-Path $resolvedTestRoot 'state-b.raw.json'
    $summaryPath = Join-Path $resolvedTestRoot 'invalid.summary.json'
    $emptyPath = Join-Path $resolvedTestRoot 'empty.raw.json'
    $outputPath = Join-Path $resolvedTestRoot 'comparison'

    @(
        [pscustomobject]@{
            frame = 100
            contextFingerprint = 'same-context'
            resolvedTotalMs = 10.0
            resolvedCpuTotalMs = 1.0
            timers = @(
                (New-Timer 'Upscaling::Synthetic' 4.0),
                (New-Timer 'VolumetricLighting::Synthetic' 2.0)
            )
        },
        [pscustomobject]@{
            frame = 101
            contextFingerprint = 'same-context'
            resolvedTotalMs = 12.0
            resolvedCpuTotalMs = 2.0
            timers = @(
                (New-Timer 'Upscaling::Synthetic' 6.0),
                (New-Timer 'VolumetricLighting::Synthetic' 1.0)
            )
        },
        [pscustomobject]@{
            frame = 102
            contextFingerprint = 'same-context'
            resolvedTotalMs = 11.0
            resolvedCpuTotalMs = 1.5
            timers = @((New-Timer 'Upscaling::Synthetic' 5.0), (New-Timer 'VolumetricLighting::Synthetic' 1.5))
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateAPath -Encoding utf8

    @(
        [pscustomobject]@{ frame = 199; contextFingerprint = 'same-context'; resolvedTotalMs = 0.0; resolvedCpuTotalMs = 0.0; timers = @() },
        [pscustomobject]@{
            frame = 200
            contextFingerprint = 'same-context'
            resolvedTotalMs = 1.0
            resolvedCpuTotalMs = 0.1
            timers = @((New-Timer 'DeferredComposite' 1.0))
        },
        [pscustomobject]@{
            frame = 201
            contextFingerprint = 'same-context'
            resolvedTotalMs = 1.1
            resolvedCpuTotalMs = 0.1
            timers = @((New-Timer 'DeferredComposite' 1.1))
        },
        [pscustomobject]@{
            frame = 202
            contextFingerprint = 'same-context'
            resolvedTotalMs = 0.9
            resolvedCpuTotalMs = 0.1
            timers = @((New-Timer 'DeferredComposite' 0.9))
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateBPath -Encoding utf8

    [pscustomobject]@{
        schemaVersion = 1
        resolvedTotalMs = [pscustomobject]@{ mean = 10.0 }
        timers = @([pscustomobject]@{ name = 'Upscaling::Synthetic'; activeGpuSamples = 2 })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    [IO.File]::WriteAllText($emptyPath, '[]', [Text.UTF8Encoding]::new($false))

    $compare = Join-Path $PSScriptRoot 'Compare-CSXProfiler.ps1'
    $result = & $compare -InputPath @($stateAPath, $stateBPath) -OutputDirectory $outputPath -ReferenceLabel 'state-a' | ConvertFrom-Json
    Assert-Test ($result.ok -and (Test-Path -LiteralPath $result.featureCsvPath -PathType Leaf)) 'comparison writes feature output'

    $states = @(Import-Csv -LiteralPath $result.csvPath)
    $stateB = @($states | Where-Object label -eq 'state-b')[0]
    Assert-Test ([int]$stateB.steadySamples -eq 3) 'comparison excludes timerless warm-up records and retains the qualified steady set'

    $features = @(Import-Csv -LiteralPath $result.featureCsvPath)
    $upscalingA = @($features | Where-Object { $_.state -eq 'state-a' -and $_.feature -eq 'Upscaling' })[0]
    $volumetricA = @($features | Where-Object { $_.state -eq 'state-a' -and $_.feature -eq 'VolumetricLighting' })[0]
    $upscalingB = @($features | Where-Object { $_.state -eq 'state-b' -and $_.feature -eq 'Upscaling' })[0]
    Assert-Test ([Math]::Abs([double]$upscalingA.weightedMeanMs - 5.0) -lt 0.000001) 'weighted feature mean uses active-sample fraction'
    Assert-Test ([Math]::Abs([double]$volumetricA.weightedMeanMs - 1.5) -lt 0.000001) 'weighted feature mean aggregates multiple samples'
    Assert-Test ([int]$upscalingB.timerCount -eq 0 -and [double]$upscalingB.weightedMeanMs -eq 0.0) 'unloaded feature emits an explicit zero row'

    $schemaError = $null
    try {
        & $compare -InputPath $summaryPath -OutputDirectory (Join-Path $resolvedTestRoot 'invalid-output') | Out-Null
    }
    catch { $schemaError = $_.Exception.Message }
    Assert-Test ($schemaError -like 'Profiler comparison requires per-sample *.raw.json input*') 'aggregated summary input fails with a specific schema error'

    $emptyError = $null
    try { & $compare -InputPath $emptyPath -OutputDirectory (Join-Path $resolvedTestRoot 'empty-output') | Out-Null }
    catch { $emptyError = $_.Exception.Message }
    Assert-Test ($emptyError -like 'Profiler input*has 0 steady samples*') 'zero-sample input fails qualification instead of producing null-derived deltas'

    $fakeControl = Join-Path $resolvedTestRoot 'Invoke-FakeDevBenchControl.ps1'
    $runtimePath = Join-Path $resolvedTestRoot 'runtime.json'
    $statePath = Join-Path $resolvedTestRoot 'profiler-state.json'
    [IO.File]::WriteAllText($runtimePath, '{}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($statePath, '{"enabled":false,"frame":0,"calls":0}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($fakeControl, @'
param([string]$Command,[string]$Tool,[string]$ArgumentsJson,[string]$RuntimePath,[string]$EvidenceDirectory,[string]$EvidenceLabel,[int]$TimeoutSeconds,[switch]$RequireSuccess,[switch]$RequirePerformanceNeutral,[switch]$NoExit,[switch]$Compact)
$state = Get-Content -LiteralPath $env:CSX_PROFILER_TEST_STATE -Raw | ConvertFrom-Json -AsHashtable
$state.calls = [int]$state.calls + 1
$action = ($ArgumentsJson | ConvertFrom-Json).action
if ($action -eq 'enable') { $state.enabled = $true }
elseif ($action -eq 'disable') { $state.enabled = $false }
elseif ($action -eq 'status') { $state.frame = [int]$state.frame + 1 }
$state | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:CSX_PROFILER_TEST_STATE -Encoding utf8
$timer = [pscustomobject]@{name='Synthetic';activeGpu=$true;activeCpu=$true;hasGpu=$true;hasCpu=$true;gpuMs=1.0;topLevelMs=1.0;cpuMs=0.1}
$status = [pscustomobject]@{enabled=[bool]$state.enabled;frame_count=[long]$state.frame;capturedFrameCount=[long]$state.frame;resolvedTotalMs=1.0;resolvedCpuTotalMs=0.1;acquiredSlots=1;slotRefusals=0;timers=@($timer)}
$listenerPid = if (-not [string]::IsNullOrWhiteSpace($env:CSX_PROFILER_TEST_DRIFT_AT_CALL) -and [int]$env:CSX_PROFILER_TEST_DRIFT_AT_CALL -eq [int]$state.calls) { 456 } else { 123 }
$data = [ordered]@{content=@([pscustomobject]@{ok=$true;status=$status})}
if ($RequirePerformanceNeutral) {
    $distorted = -not [string]::IsNullOrWhiteSpace($env:CSX_PROFILER_TEST_DISTORT_ACTION) -and $env:CSX_PROFILER_TEST_DISTORT_ACTION -eq $action
    $guard = [pscustomobject]@{applicable=$true;neutral=(-not $distorted);performanceDistorted=$distorted;performanceEpoch=7;physicalStateKnown=$true;reason=$(if ($distorted) {'intrusive-temporal-probe-active'} else {'intrusive-temporal-probe-disarmed'})}
    $data.performanceGuard = $guard
    $data.performanceWindow = [pscustomobject]@{valid=(-not $distorted);applicable=$true;sameEpoch=$true;before=$guard;after=$guard;reason=$(if ($distorted) {'performance-probe-distorted'} else {'performance-window-neutral'})}
}
[pscustomobject]@{ok=$true;runtimeIdentity=[pscustomobject]@{complete=$true;verified=$true;listenerPid=$listenerPid;process=[pscustomobject]@{path='C:\Fixture\SkyrimVR.exe';startTimeUtc='2026-08-28T00:00:00Z'};build=[pscustomobject]@{buildId='fixture'};artifact=[pscustomobject]@{path='C:\Fixture\CommunityShaders.dll';sha256='AA'}};invocationEvidencePath=(Join-Path $EvidenceDirectory "$EvidenceLabel.json");data=[pscustomobject]$data;errors=@()} | ConvertTo-Json -Depth 20 -Compress
'@, [Text.UTF8Encoding]::new($false))
    $env:CSX_PROFILER_TEST_STATE = $statePath
    $env:CSX_PROFILER_CONTROL_ROOT = Join-Path $resolvedTestRoot 'profiler-control'
    $measure = Join-Path $PSScriptRoot 'Measure-CSXProfiler.ps1'
    $contextJson = @{ environment = @{ mo2Profile = 'fixture'; scene = 'still'; hmdMode = 'null'; renderResolution = '100x100' }; treatment = @{ shaderState = 'enabled' } } | ConvertTo-Json -Compress
    $measurement = & $measure -Label fixture -EvidenceDirectory (Join-Path $resolvedTestRoot 'measure') -ContextJson $contextJson -Samples 3 -WarmupSamples 0 -IntervalMs 50 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | ConvertFrom-Json
    $finalProfilerState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Test ($measurement.ok -and $measurement.summary.uniqueFreshFrames -eq 3 -and $measurement.summary.profilerStateRestored) 'measurement uses fresh frames and records verified state restoration'
    Assert-Test (-not $finalProfilerState.enabled) 'measurement restores the exact prior profiler enable state'
    $measuredRecords = @(Get-Content -LiteralPath $measurement.rawPath -Raw | ConvertFrom-Json)
    $measurementReceipt = Get-Content -LiteralPath $measurement.receiptPath -Raw | ConvertFrom-Json
    Assert-Test (@($measuredRecords.runtimeIdentityFingerprint | Sort-Object -Unique).Count -eq 1 -and @($measurementReceipt.runtimeIdentityObservations).Count -ge 7) 'measurement binds every accepted response and sample to one verified runtime identity'
    Assert-Test ($measurement.summary.schemaVersion -eq 3 -and @($measurement.summary.performanceObservations).Count -ge 5) 'measurement preserves performance-neutrality evidence in summary schema 3'
    Assert-Test (@($measurement.summary.performanceObservations | Where-Object { -not $_.window.valid -or $_.guard.performanceEpoch -ne 7 }).Count -eq 0) 'measurement retains one valid performance epoch across the capture'

    $recoveryMirror = Join-Path $resolvedTestRoot 'interrupted-profiler.journal.json'
    $authoritativeJournal = Join-Path $env:CSX_PROFILER_CONTROL_ROOT 'transaction.journal.json'
    [ordered]@{contractVersion='1.0.0';operation='measure-profiler';transactionId='interrupted-fixture';phase='sampling';runtimePath=$runtimePath;runtimeIdentityFingerprint=$measurement.summary.runtimeIdentityFingerprint;priorEnabled=$false;evidenceMirrorPath=$recoveryMirror;preparedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $authoritativeJournal -Encoding utf8
    [IO.File]::WriteAllText($statePath, '{"enabled":true,"frame":0,"calls":0}', [Text.UTF8Encoding]::new($false))
    $recoveredMeasurement = & $measure -Label restart-recovery -EvidenceDirectory (Join-Path $resolvedTestRoot 'recovery') -ContextJson $contextJson -Samples 3 -WarmupSamples 0 -IntervalMs 50 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | ConvertFrom-Json
    $recoveredPriorJournal = Get-Content -LiteralPath $recoveryMirror -Raw | ConvertFrom-Json
    $recoveredFinalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Test ($recoveredMeasurement.ok -and $recoveredPriorJournal.phase -eq 'recovered-preimage' -and $recoveredPriorJournal.recovery.stateRestored -and -not $recoveredFinalState.enabled) 'next capture discovers a dead capture journal and restores the same runtime exact prior state'

    [IO.File]::WriteAllText($statePath, '{"enabled":false,"frame":0,"calls":0}', [Text.UTF8Encoding]::new($false))
    $env:CSX_PROFILER_TEST_DRIFT_AT_CALL = '3'
    $driftError = $null
    try { & $measure -Label identity-drift -EvidenceDirectory (Join-Path $resolvedTestRoot 'drift') -ContextJson $contextJson -Samples 3 -WarmupSamples 0 -IntervalMs 50 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | Out-Null }
    catch { $driftError = $_.Exception.Message }
    Remove-Item Env:CSX_PROFILER_TEST_DRIFT_AT_CALL -ErrorAction SilentlyContinue
    $driftFinalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Test ($driftError -match 'runtime identity changed' -and -not $driftFinalState.enabled) 'measurement rejects a replacement runtime and restores state only through the original identity'

    [IO.File]::WriteAllText($statePath, '{"enabled":false,"frame":0,"calls":0}', [Text.UTF8Encoding]::new($false))
    $env:CSX_PROFILER_TEST_DISTORT_ACTION = 'status'
    $distortionError = $null
    try { & $measure -Label performance-distortion -EvidenceDirectory (Join-Path $resolvedTestRoot 'distortion') -ContextJson $contextJson -Samples 3 -WarmupSamples 0 -IntervalMs 50 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | Out-Null }
    catch { $distortionError = $_.Exception.Message }
    Remove-Item Env:CSX_PROFILER_TEST_DISTORT_ACTION -ErrorAction SilentlyContinue
    $distortionFinalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Test ($distortionError -match 'performance-neutrality window' -and -not $distortionFinalState.enabled) 'measurement fails closed on a distorted performance probe and restores profiler state'

    [IO.File]::WriteAllText($statePath, '{"enabled":false,"frame":0,"calls":0}', [Text.UTF8Encoding]::new($false))
    $deadlineWatch = [Diagnostics.Stopwatch]::StartNew()
    $deadlineError = $null
    try { & $measure -Label deadline -EvidenceDirectory (Join-Path $resolvedTestRoot 'deadline') -ContextJson $contextJson -Samples 3 -WarmupSamples 100 -IntervalMs 50 -TotalTimeoutSeconds 5 -RestoreReserveSeconds 2 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | Out-Null }
    catch { $deadlineError = $_.Exception.Message }
    $deadlineWatch.Stop()
    $deadlineFinalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Test ($deadlineError -match 'deadline expired' -and $deadlineWatch.Elapsed.TotalSeconds -lt 5 -and -not $deadlineFinalState.enabled) 'measurement enforces one total deadline while reserving bounded state restoration time'

    $leasePath = Join-Path $env:CSX_PROFILER_CONTROL_ROOT 'capture.lock'
    New-Item -ItemType Directory -Path (Split-Path -Parent $leasePath) -Force | Out-Null
    $heldLease = [IO.File]::Open($leasePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $leaseError = $null
        try { & $measure -Label contention -EvidenceDirectory (Join-Path $resolvedTestRoot 'contention') -ContextJson $contextJson -Samples 3 -WarmupSamples 0 -IntervalMs 50 -LeaseTimeoutSeconds 1 -RuntimePath $runtimePath -DevBenchControlPath $fakeControl | Out-Null }
        catch { $leaseError = $_.Exception.Message }
        Assert-Test ($leaseError -match 'Timed out waiting for the profiler capture lease') 'measurement serializes captures for the same runtime under one bounded lease'
    }
    finally { $heldLease.Dispose() }

    $measureText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Measure-CSXProfiler.ps1') -Raw
    Assert-Test ($measureText -match '-RequirePerformanceNeutral:\(-not \$ForRestore\)') 'capture guards measurement calls while preserving the restoration path'
    Assert-Test ($measureText -match '\$expectedPerformanceEpoch') 'capture pins the performance ownership epoch across samples'
    Assert-Test ($measureText -match 'schemaVersion = 3') 'capture stores performance guard evidence under schema 3'
    Assert-Test ($measureText.IndexOf(
        'Get-DevBenchRenderScalePreparationTelemetry',
        [StringComparison]::Ordinal
    ) -ge 0) 'profiler capture retains render-scale preparation telemetry'
    Assert-Test ($null -ne $measurement.summary.preparation.before -and
        $null -ne $measurement.summary.preparation.after) 'profiler summary exposes before and after preparation traces'

    $profilerSkill = Get-Content -LiteralPath (Join-Path $PSScriptRoot `
        '..\..\skills\profiler-control\SKILL.md') -Raw
    Assert-Test ($profilerSkill.IndexOf(
        '`set_enabled` with `enabled: true`',
        [StringComparison]::Ordinal
    ) -ge 0) 'profiler contract enables the versioned API before capture'
    Assert-Test ($profilerSkill.IndexOf(
        'Treat `disabled` from `start_capture` as a failed capture',
        [StringComparison]::Ordinal
    ) -ge 0) 'profiler contract fails closed on a disabled capture'
    Assert-Test ($profilerSkill.IndexOf(
        'Restore the initial enabled state',
        [StringComparison]::Ordinal
    ) -ge 0) 'profiler contract restores caller-owned state'
}
finally {
    Remove-Item Env:CSX_PROFILER_TEST_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:CSX_PROFILER_TEST_DRIFT_AT_CALL -ErrorAction SilentlyContinue
    Remove-Item Env:CSX_PROFILER_CONTROL_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    passed = $passes.Count
    failed = $failures.Count
    passes = @($passes)
    failures = @($failures)
} | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
