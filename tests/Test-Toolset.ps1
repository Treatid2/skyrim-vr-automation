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
    @{ Name = 'mo2-control'; Path = 'tools\mo2-control\tests\Test-MO2Control.ps1'; Arguments = $(if ($IncludeLiveMO2) { @('-IncludeLive') } else { @() }) },
    @{ Name = 'mo2-profile-control'; Path = 'tools\mo2-profile-control\tests\Test-MO2ProfileControl.ps1'; Arguments = @() },
    @{ Name = 'steamvr-null-control'; Path = 'tools\steamvr-null-control\Test-SteamVRNullControl.ps1'; Arguments = @() },
    @{ Name = 'devbench-control'; Path = 'tools\devbench-control\Test-DevBenchControl.ps1'; Arguments = @() },
    @{ Name = 'profiler-control'; Path = 'tools\profiler-control\Test-ProfilerControl.ps1'; Arguments = @() },
    @{ Name = 'shader-cache-control'; Path = 'tools\shader-cache-control\Test-CSXShaderCacheControl.ps1'; Arguments = @() },
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
