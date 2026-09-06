# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$InputPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ReferenceLabel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($InputPath.Count -lt 2) { throw 'At least two quiet-window captures are required.' }
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$rows = [Collections.Generic.List[object]]::new()
foreach ($path in $InputPath) {
    $resolved = [IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Capture not found: $resolved" }
    $capture = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 30
    if ([int]$capture.schemaVersion -ne 1 -or $null -eq $capture.engineFps) {
        throw "Unsupported quiet-window capture schema: $resolved"
    }
    $skyrim = @($capture.processes | Where-Object name -eq 'SkyrimVR' | Select-Object -First 1)
    $vrserver = @($capture.processes | Where-Object name -eq 'vrserver' | Select-Object -First 1)
    $scene = if ($capture.PSObject.Properties.Name -contains 'scene' -and
        -not [string]::IsNullOrWhiteSpace([string]$capture.scene)) {
        [string]$capture.scene
    } else {
        'unspecified'
    }
    $rows.Add([pscustomobject][ordered]@{
        label = [string]$capture.condition
        scene = $scene
        path = $resolved
        elapsedSeconds = [double]$capture.elapsedSeconds
        engineFps = [double]$capture.engineFps
        skyrimAverageCores = if ($skyrim.Count) { [double]$skyrim[0].averageCores } else { $null }
        vrserverAverageCores = if ($vrserver.Count) { [double]$vrserver[0].averageCores } else { $null }
    })
}

$referenceMatches = if ([string]::IsNullOrWhiteSpace($ReferenceLabel)) {
    @($rows[0])
} else {
    @($rows | Where-Object label -eq $ReferenceLabel | Select-Object -First 1)
}
$reference = if ($referenceMatches.Count -gt 0) { $referenceMatches[0] } else { $null }
if ($null -eq $reference) { throw "Reference label not found: $ReferenceLabel" }

$comparison = @($rows | ForEach-Object {
    [pscustomobject][ordered]@{
        label = $_.label
        scene = $_.scene
        path = $_.path
        elapsedSeconds = $_.elapsedSeconds
        engineFps = $_.engineFps
        fpsDelta = $_.engineFps - $reference.engineFps
        fpsDeltaPercent = if ($reference.engineFps -ne 0) { 100.0 * ($_.engineFps - $reference.engineFps) / $reference.engineFps } else { $null }
        skyrimAverageCores = $_.skyrimAverageCores
        skyrimCoreDelta = if ($null -ne $_.skyrimAverageCores -and $null -ne $reference.skyrimAverageCores) { $_.skyrimAverageCores - $reference.skyrimAverageCores } else { $null }
        vrserverAverageCores = $_.vrserverAverageCores
        vrserverCoreDelta = if ($null -ne $_.vrserverAverageCores -and $null -ne $reference.vrserverAverageCores) { $_.vrserverAverageCores - $reference.vrserverAverageCores } else { $null }
    }
})

$jsonPath = Join-Path $resolvedOutput 'skyrim-performance-comparison.json'
$csvPath = Join-Path $resolvedOutput 'skyrim-performance-comparison.csv'
$markdownPath = Join-Path $resolvedOutput 'skyrim-performance-comparison.md'
[IO.File]::WriteAllText($jsonPath, ([pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'skyrim-vr-performance-comparison'
    generatedUtc = [datetime]::UtcNow.ToString('o')
    referenceLabel = $reference.label
    informationalOnly = $true
    rows = $comparison
} | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$comparison | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Skyrim VR performance comparison')
$lines.Add('')
$lines.Add("Reference: ``$($reference.label)``. Results are informational; this tool does not impose stability thresholds.")
$lines.Add('')
$lines.Add('| Condition | Scene | FPS | Δ FPS | Δ FPS % | Skyrim cores | Δ cores | vrserver cores |')
$lines.Add('|---|---:|---:|---:|---:|---:|---:|---:|')
foreach ($row in $comparison) {
    $lines.Add(('| {0} | {1} | {2:N3} | {3:N3} | {4:N2}% | {5:N3} | {6:N3} | {7:N3} |' -f `
        ($row.label -replace '\|','\|'), ($row.scene -replace '\|','\|'), $row.engineFps, $row.fpsDelta,
        $row.fpsDeltaPercent, $row.skyrimAverageCores, $row.skyrimCoreDelta, $row.vrserverAverageCores))
}
[IO.File]::WriteAllLines($markdownPath, $lines, [Text.UTF8Encoding]::new($false))

[pscustomobject][ordered]@{
    ok = $true
    referenceLabel = $reference.label
    captureCount = $comparison.Count
    jsonPath = $jsonPath
    csvPath = $csvPath
    markdownPath = $markdownPath
} | ConvertTo-Json
