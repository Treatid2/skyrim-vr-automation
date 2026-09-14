# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [switch]$IncludeLiveMO2,
    [ValidateRange(30, 3600)][int]$PerSuiteTimeoutSeconds = 600,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$powerShell = (Get-Process -Id $PID).Path
$boundedProcess = Join-Path $repositoryRoot 'tools\process-control\Invoke-BoundedProcess.ps1'
$aggregateWatch = [Diagnostics.Stopwatch]::StartNew()
$resolvedEvidenceDirectory = if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $null } else { [IO.Path]::GetFullPath($EvidenceDirectory) }
if ($null -ne $resolvedEvidenceDirectory) { New-Item -ItemType Directory -Path $resolvedEvidenceDirectory -Force | Out-Null }
$tests = @(
    @{ Name = 'feedback-control'; Path = 'tools\feedback-control\Test-AutomationFeedback.ps1'; Arguments = @() },
    @{ Name = 'mo2-control'; Path = 'tools\mo2-control\tests\Test-MO2Control.ps1'; Arguments = $(if ($IncludeLiveMO2) { @('-IncludeLive') } else { @() }) },
    @{ Name = 'mo2-profile-control'; Path = 'tools\mo2-profile-control\tests\Test-MO2ProfileControl.ps1'; Arguments = @() },
    @{ Name = 'mo2-workspace-control'; Path = 'tools\mo2-workspace-control\tests\Test-MO2WorkspaceControl.ps1'; Arguments = @() },
    @{ Name = 'steamvr-null-control'; Path = 'tools\steamvr-null-control\Test-SteamVRNullControl.ps1'; Arguments = @() },
    @{ Name = 'steamvr-head-pose-control'; Path = 'tools\steamvr-head-pose-control\Test-SteamVRHeadPoseControl.ps1'; Arguments = @() },
    @{ Name = 'devbench-control'; Path = 'tools\devbench-control\Test-DevBenchControl.ps1'; Arguments = @() },
    @{ Name = 'capture-interaction-control'; Path = 'tools\capture-interaction-control\Test-CaptureInteractionControl.ps1'; Arguments = @() },
    @{ Name = 'coc-evidence-control'; Path = 'tools\coc-evidence-control\Test-CocEvidenceControl.ps1'; Arguments = @() },
    @{ Name = 'coc-stability-control'; Path = 'tools\coc-stability-control\Test-CocStabilityControl.ps1'; Arguments = @() },
    @{ Name = 'coc-stability-protocol'; Path = 'tests\Test-CocStabilityProtocol.ps1'; Arguments = @() },
    @{ Name = 'simple-coc-5-protocol'; Path = 'tests\Test-SimpleCoc5Protocol.ps1'; Arguments = @() },
    @{ Name = 'simple-coc-protocol'; Path = 'tests\Test-SimpleCocProtocol.ps1'; Arguments = @() },
    @{ Name = 'static-coc-protocol'; Path = 'tests\Test-StaticCocProtocol.ps1'; Arguments = @() },
    @{ Name = 'profiler-control'; Path = 'tools\profiler-control\Test-ProfilerControl.ps1'; Arguments = @() },
    @{ Name = 'render-scale-visual-provider'; Path = 'tools\render-scale-qualification\Test-AutomatedVisualReviewProvider.ps1'; Arguments = @() },
    @{ Name = 'render-scale-entrypoint'; Path = 'tools\render-scale-qualification\Test-RenderScaleQualificationEntrypoint.ps1'; Arguments = @() },
    @{ Name = 'render-scale-qualification'; Path = 'tools\render-scale-qualification\Test-CSXRenderScaleQualification.ps1'; Arguments = @() },
    @{ Name = 'render-scale-tuning-protocol'; Path = 'tests\Test-RenderScaleTuningProtocol.ps1'; Arguments = @() },
    @{ Name = 'render-scale-ledger-contract'; Path = 'tests\Test-RenderScaleLedgerContract.ps1'; Arguments = @() },
    @{ Name = 'shader-cache-control'; Path = 'tools\shader-cache-control\Test-CSXShaderCacheControl.ps1'; Arguments = @() },
    @{ Name = 'shader-cache-catalog'; Path = 'tools\shader-cache-control\Test-CSXShaderCacheCatalog.ps1'; Arguments = @() },
    @{ Name = 'process-control'; Path = 'tools\process-control\Test-BoundedProcess.ps1'; Arguments = @() },
    @{ Name = 'build-test-control'; Path = 'tools\build-test-control\Test-CSXBuildTests.ps1'; Arguments = @() },
    @{ Name = 'doctor'; Path = 'tools\doctor\Test-AutomationDoctor.ps1'; Arguments = @() },
    @{ Name = 'codex-distribution'; Path = 'tests\Test-CodexDistribution.ps1'; Arguments = @() },
    @{ Name = 'portability'; Path = 'tests\Test-Portability.ps1'; Arguments = @() },
    @{ Name = 'publication'; Path = 'tests\Test-Publication.ps1'; Arguments = @() }
)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($test in $tests) {
    $path = Join-Path $repositoryRoot $test.Path
    $arguments = @($test.Arguments)
    $suiteWatch = [Diagnostics.Stopwatch]::StartNew()
    [Console]::Error.WriteLine("[toolset $([Math]::Round($aggregateWatch.Elapsed.TotalSeconds, 1))s] starting '$($test.Name)' (limit ${PerSuiteTimeoutSeconds}s)")
    $boundedArguments = @{
        FilePath = $powerShell
        ArgumentList = @('-NoProfile', '-File', $path) + $arguments
        WorkingDirectory = $repositoryRoot
        MaxAttempts = 1
        TimeoutSeconds = $PerSuiteTimeoutSeconds
        NoExit = $true
        Compact = $true
    }
    if ($null -ne $resolvedEvidenceDirectory) {
        $suiteEvidenceDirectory = Join-Path $resolvedEvidenceDirectory $test.Name
        New-Item -ItemType Directory -Path $suiteEvidenceDirectory -Force | Out-Null
        $boundedArguments.EvidenceDirectory = $suiteEvidenceDirectory
    }
    $bounded = & $boundedProcess @boundedArguments | ConvertFrom-Json -Depth 30
    $attempt = @($bounded.attempts | Select-Object -Last 1)
    $lastAttempt = if ($attempt.Count -eq 1) { $attempt[0] } else { $null }
    $output = @(
        if ($null -ne $lastAttempt -and $null -ne $lastAttempt.stdout) { [string]$lastAttempt.stdout -split '\r?\n' | Where-Object { $_ -match '\S' } }
        if ($null -ne $lastAttempt -and $null -ne $lastAttempt.stderr) { [string]$lastAttempt.stderr -split '\r?\n' | Where-Object { $_ -match '\S' } }
    )
    $exitCode = if ($null -ne $lastAttempt -and $null -ne $lastAttempt.exitCode) { [int]$lastAttempt.exitCode } else { $null }
    $suiteWatch.Stop()
    [Console]::Error.WriteLine("[toolset $([Math]::Round($aggregateWatch.Elapsed.TotalSeconds, 1))s] completed '$($test.Name)': $(if ($bounded.ok) { 'PASS' } elseif ($null -ne $lastAttempt -and $lastAttempt.timedOut) { 'TIMEOUT' } else { 'FAIL' }) in $([Math]::Round($suiteWatch.Elapsed.TotalSeconds, 1))s")
    $results.Add([pscustomobject][ordered]@{
        name = $test.Name
        ok = [bool]$bounded.ok
        exitCode = $exitCode
        elapsedMs = [long]$bounded.elapsedMs
        timeoutSeconds = $PerSuiteTimeoutSeconds
        timedOut = [bool]($null -ne $lastAttempt -and $lastAttempt.timedOut)
        terminationConfirmed = [bool]($null -ne $lastAttempt -and $lastAttempt.terminationConfirmed)
        receiptPath = $(if ($null -ne $bounded.PSObject.Properties['receiptPath']) { [string]$bounded.receiptPath } else { $null })
        errors = @($bounded.errors)
        output = @($output | ForEach-Object { [string]$_ })
    })
}

$failed = @($results | Where-Object { -not $_.ok })
$summary = [pscustomobject][ordered]@{
    ok = $failed.Count -eq 0
    passed = @($results | Where-Object ok).Count
    failed = $failed.Count
    elapsedMs = [long]$aggregateWatch.Elapsed.TotalMilliseconds
    perSuiteTimeoutSeconds = $PerSuiteTimeoutSeconds
    results = @($results)
}
$summary | ConvertTo-Json -Depth 10
if (-not $summary.ok) { exit 1 }
