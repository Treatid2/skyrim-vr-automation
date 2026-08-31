# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [switch]$IncludeLiveMO2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$powerShell = (Get-Process -Id $PID).Path
$tests = @(
    @{ Name = 'modlist-control'; Path = 'tools\modlist-control\Test-ModlistControl.ps1'; Arguments = @() },
    @{ Name = 'feedback-control'; Path = 'tools\feedback-control\Test-AutomationFeedback.ps1'; Arguments = @() },
    @{ Name = 'mo2-control'; Path = 'tools\mo2-control\tests\Test-MO2Control.ps1'; Arguments = $(if ($IncludeLiveMO2) { @('-IncludeLive') } else { @() }) },
    @{ Name = 'mo2-profile-control'; Path = 'tools\mo2-profile-control\tests\Test-MO2ProfileControl.ps1'; Arguments = @() },
    @{ Name = 'mo2-workspace-control'; Path = 'tools\mo2-workspace-control\tests\Test-MO2WorkspaceControl.ps1'; Arguments = @() },
    @{ Name = 'steamvr-null-control'; Path = 'tools\steamvr-null-control\Test-SteamVRNullControl.ps1'; Arguments = @() },
    @{ Name = 'steamvr-head-pose-control'; Path = 'tools\steamvr-head-pose-control\Test-SteamVRHeadPoseControl.ps1'; Arguments = @() },
    @{ Name = 'devbench-control'; Path = 'tools\devbench-control\Test-DevBenchControl.ps1'; Arguments = @() },
    @{ Name = 'render-scale-qualification'; Path = 'tools\render-scale-qualification\Test-CSXRenderScaleQualification.ps1'; Arguments = @() },
    @{ Name = 'capture-interaction-control'; Path = 'tools\capture-interaction-control\Test-CaptureInteractionControl.ps1'; Arguments = @() },
    @{ Name = 'profiler-control'; Path = 'tools\profiler-control\Test-ProfilerControl.ps1'; Arguments = @() },
    @{ Name = 'shader-cache-control'; Path = 'tools\shader-cache-control\Test-CSXShaderCacheControl.ps1'; Arguments = @() },
    @{ Name = 'shader-cache-catalog'; Path = 'tools\shader-cache-control\Test-CSXShaderCacheCatalog.ps1'; Arguments = @() },
    @{ Name = 'process-control'; Path = 'tools\process-control\Test-BoundedProcess.ps1'; Arguments = @() },
    @{ Name = 'windows-thread-context'; Path = 'tools\process-control\Test-WindowsThreadContext.ps1'; Arguments = @() },
    @{ Name = 'coc-evidence-control'; Path = 'tools\coc-evidence-control\Test-CocEvidenceControl.ps1'; Arguments = @() },
    @{ Name = 'coc-stability-control'; Path = 'tools\coc-stability-control\Test-CocStabilityControl.ps1'; Arguments = @() },
    @{ Name = 'build-test-control'; Path = 'tools\build-test-control\Test-CSXBuildTests.ps1'; Arguments = @() },
    @{ Name = 'doctor'; Path = 'tools\doctor\Test-AutomationDoctor.ps1'; Arguments = @() },
    @{ Name = 'git-launcher'; Path = 'tests\Test-GitLauncher.ps1'; Arguments = @() },
    @{ Name = 'coc-stability-protocol'; Path = 'tests\Test-CocStabilityProtocol.ps1'; Arguments = @() },
    @{ Name = 'simple-coc-protocol'; Path = 'tests\Test-SimpleCocProtocol.ps1'; Arguments = @() },
    @{ Name = 'simple-coc-ghidra'; Path = 'tests\Test-SimpleCocGhidra.ps1'; Arguments = @() },
    @{ Name = 'simple-coc-5-protocol'; Path = 'tests\Test-SimpleCoc5Protocol.ps1'; Arguments = @() },
    @{ Name = 'simple-csm-protocol'; Path = 'tests\Test-SimpleCSMProtocol.ps1'; Arguments = @() },
    @{ Name = 'renderscale-tuning-protocol'; Path = 'tests\Test-RenderScaleTuningProtocol.ps1'; Arguments = @() },
    @{ Name = 'static-coc-protocol'; Path = 'tests\Test-StaticCocProtocol.ps1'; Arguments = @() },
    @{ Name = 'codex-plugin-registration'; Path = 'tests\Test-CodexPluginRegistration.ps1'; Arguments = @() },
    @{ Name = 'codex-distribution'; Path = 'tests\Test-CodexDistribution.ps1'; Arguments = @() },
    @{ Name = 'portability'; Path = 'tests\Test-Portability.ps1'; Arguments = @() },
    @{ Name = 'publication'; Path = 'tests\Test-Publication.ps1'; Arguments = @() }
)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($test in $tests) {
    $path = Join-Path $repositoryRoot $test.Path
    $arguments = @($test.Arguments)
    $output = & $powerShell -NoProfile -File $path @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $results.Add([pscustomobject][ordered]@{
        name = $test.Name
        ok = $exitCode -eq 0
        exitCode = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
    })
}

$failed = @($results | Where-Object { -not $_.ok })
$summary = [pscustomobject][ordered]@{
    ok = $failed.Count -eq 0
    passed = @($results | Where-Object ok).Count
    failed = $failed.Count
    results = @($results)
}
$summary | ConvertTo-Json -Depth 10
if (-not $summary.ok) { exit 1 }
