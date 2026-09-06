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
    [pscustomobject]@{ ok = $true; tests = 4 } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $root -PathType Container) { Remove-Item -LiteralPath $root -Recurse -Force }
}
