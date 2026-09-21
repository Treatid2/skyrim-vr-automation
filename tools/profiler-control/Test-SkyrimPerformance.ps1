# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-performance-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    function Write-Capture([string]$Name, [double]$Fps, [double]$GameCores, [double]$VrserverCores) {
        $path = Join-Path $root "$Name.json"
        $capture = [pscustomobject][ordered]@{
            schemaVersion = 1
            condition = $Name
            elapsedSeconds = 30
            engineFps = $Fps
            processes = @(
                [pscustomobject]@{ name = 'SkyrimVR'; averageCores = $GameCores },
                [pscustomobject]@{ name = 'vrserver'; averageCores = $VrserverCores }
            )
        }
        if ($Name -ne 'candidate') { $capture | Add-Member -NotePropertyName scene -NotePropertyValue 'SyntheticScene' }
        $capture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
    $a = Write-Capture 'baseline' 20 2.0 0.9
    $b = Write-Capture 'candidate' 22 2.2 0.1
    $result = & (Join-Path $PSScriptRoot 'Compare-SkyrimPerformance.ps1') -InputPath @($a, $b) `
        -OutputDirectory (Join-Path $root 'out') -ReferenceLabel baseline | ConvertFrom-Json
    if (-not $result.ok -or $result.captureCount -ne 2) { throw 'Comparison did not return two captures.' }
    $comparison = Get-Content -LiteralPath $result.jsonPath -Raw | ConvertFrom-Json
    $candidate = @($comparison.rows | Where-Object label -eq candidate)[0]
    if ([math]::Abs([double]$candidate.fpsDelta - 2.0) -gt 0.000001) { throw 'FPS delta is incorrect.' }
    if ([math]::Abs([double]$candidate.fpsDeltaPercent - 10.0) -gt 0.000001) { throw 'FPS percent delta is incorrect.' }
    if ([math]::Abs([double]$candidate.skyrimCoreDelta - 0.2) -gt 0.000001) { throw 'CPU-core delta is incorrect.' }
    if ($candidate.scene -ne 'unspecified') { throw 'Legacy capture without scene was not normalized.' }

    $quietControl = Join-Path $root 'fake-quiet-devbench.ps1'
    $quietState = Join-Path $root 'quiet-state.txt'
    '0' | Set-Content -LiteralPath $quietState -Encoding ascii
    $quietRuntime = Join-Path $root 'runtime.json'
    '{}' | Set-Content -LiteralPath $quietRuntime -Encoding utf8
    [IO.File]::WriteAllText($quietControl, @'
param([string]$Command,[string]$Tool,[string]$ArgumentsJson,[string]$RuntimePath,[string]$EvidenceDirectory,[string]$EvidenceLabel,[switch]$NoExit,[switch]$Compact)
Start-Sleep -Milliseconds 100
$frame = [int](Get-Content -LiteralPath $env:CSX_QUIET_TEST_STATE -Raw)
$frame += 120
$frame | Set-Content -LiteralPath $env:CSX_QUIET_TEST_STATE -Encoding ascii
[pscustomobject]@{ok=$true;runtimeIdentity=[pscustomobject]@{health=[pscustomobject]@{pid=$PID;exe='fixture';frame=$frame};build=[pscustomobject]@{buildId='fixture'}}} | ConvertTo-Json -Depth 8 -Compress
'@, [Text.UTF8Encoding]::new($false))
    $env:CSX_QUIET_TEST_STATE = $quietState
    $quietOutput = Join-Path $root 'quiet.json'
    $quiet = & (Join-Path $PSScriptRoot 'Measure-SkyrimQuietWindow.ps1') -OutputPath $quietOutput -Condition fixture -Scene SyntheticScene -RuntimePath $quietRuntime -Samples 2 -IntervalMilliseconds 50 -DevBenchControlPath $quietControl | ConvertFrom-Json
    $quietCapture = Get-Content -LiteralPath $quietOutput -Raw | ConvertFrom-Json
    if (-not $quiet.ok -or $quietCapture.schemaVersion -ne 2 -or $quietCapture.frameCounterElapsedSeconds -le $quietCapture.elapsedSeconds -or $quietCapture.measurementIntervals.frameBoundaryMethod -ne 'request-midpoint') { throw 'Quiet-window counters did not use their matched observation intervals.' }
    Remove-Item Env:CSX_QUIET_TEST_STATE -ErrorAction SilentlyContinue
    [pscustomobject]@{ ok = $true; tests = 5 } | ConvertTo-Json
}
finally {
    Remove-Item Env:CSX_QUIET_TEST_STATE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root -PathType Container) { Remove-Item -LiteralPath $root -Recurse -Force }
}
