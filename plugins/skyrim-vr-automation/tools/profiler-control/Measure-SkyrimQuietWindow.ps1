# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Condition,
    [Parameter(Mandatory)][string]$Scene,
    [Parameter(Mandatory)][string]$RuntimePath,
    [int]$Samples = 60,
    [int]$IntervalMilliseconds = 500,
    [string]$DevBenchControlPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Samples -lt 2) { throw 'Samples must be at least 2.' }
if ($IntervalMilliseconds -lt 50) { throw 'IntervalMilliseconds must be at least 50.' }
foreach ($required in @($RuntimePath, $DevBenchControlPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file not found: $required" }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$directory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $directory -Force | Out-Null

function Invoke-HealthBoundary([string]$Label) {
    $startedTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $raw = & $DevBenchControlPath call -Tool inspect -ArgumentsJson '{"kind":"health"}' `
        -RuntimePath $RuntimePath -EvidenceDirectory $directory -EvidenceLabel $Label -NoExit -Compact
    $completedTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    if (-not $?) { throw "DevBench health boundary '$Label' failed." }
    $receipt = $raw | ConvertFrom-Json -Depth 60
    if (-not $receipt.ok -or $null -eq $receipt.runtimeIdentity.health) {
        throw "DevBench health boundary '$Label' did not return verified health."
    }
    return [pscustomobject][ordered]@{
        receipt = $receipt
        sampledTicks = [long]($startedTicks + [long](($completedTicks - $startedTicks) / 2))
        requestStartedTicks = $startedTicks
        requestCompletedTicks = $completedTicks
    }
}

$before = Invoke-HealthBoundary 'quiet-window-before'
$gamePid = [int]$before.receipt.runtimeIdentity.health.pid
$trackedNames = @('SkyrimVR', 'vrserver', 'vrcompositor', 'vrdashboard', 'VirtualDesktop.Streamer', 'VirtualDesktop.Server')
$tracked = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in $trackedNames })
$cpuBefore = @{}
foreach ($process in $tracked) {
    $cpuBefore[[string]$process.Id] = [pscustomobject]@{
        cpuSeconds = [double]$process.CPU
        sampledTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    }
}

$sampleRows = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($index = 0; $index -lt $Samples; $index++) {
    $game = Get-Process -Id $gamePid -ErrorAction Stop
    $sampleRows.Add([pscustomobject][ordered]@{
        tMs = [int64]$clock.ElapsedMilliseconds
        gameCpu = [double]$game.CPU
        workingSet = [int64]$game.WorkingSet64
        privateBytes = [int64]$game.PrivateMemorySize64
    })
    Start-Sleep -Milliseconds $IntervalMilliseconds
}
$clock.Stop()

$after = Invoke-HealthBoundary 'quiet-window-after'
if ([int]$after.receipt.runtimeIdentity.health.pid -ne $gamePid) { throw 'Skyrim process identity changed during the quiet window.' }

$processRows = [Collections.Generic.List[object]]::new()
foreach ($process in $tracked) {
    $current = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if ($null -eq $current) { continue }
    $sampledTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $baseline = $cpuBefore[[string]$process.Id]
    $delta = [double]$current.CPU - [double]$baseline.cpuSeconds
    $processElapsedSeconds = ($sampledTicks - [long]$baseline.sampledTicks) / [double][Diagnostics.Stopwatch]::Frequency
    $processRows.Add([pscustomobject][ordered]@{
        pid = $process.Id
        name = $process.ProcessName
        cpuSecondsDelta = $delta
        elapsedSeconds = $processElapsedSeconds
        averageCores = [math]::Round($delta / $processElapsedSeconds, 6)
    })
}

$frameStart = [double]$before.receipt.runtimeIdentity.health.frame
$frameEnd = [double]$after.receipt.runtimeIdentity.health.frame
$frameElapsedSeconds = ($after.sampledTicks - $before.sampledTicks) / [double][Diagnostics.Stopwatch]::Frequency
$result = [pscustomobject][ordered]@{
    schemaVersion = 2
    kind = 'skyrim-vr-quiet-window'
    capturedUtc = [datetime]::UtcNow.ToString('o')
    condition = $Condition
    scene = $Scene
    runtime = [pscustomobject][ordered]@{
        pid = $gamePid
        exe = $before.receipt.runtimeIdentity.health.exe
        buildId = $before.receipt.runtimeIdentity.build.buildId
    }
    elapsedSeconds = $clock.Elapsed.TotalSeconds
    frameCounterElapsedSeconds = $frameElapsedSeconds
    frameStart = $frameStart
    frameEnd = $frameEnd
    frameDelta = $frameEnd - $frameStart
    engineFps = ($frameEnd - $frameStart) / $frameElapsedSeconds
    measurementIntervals = [pscustomobject][ordered]@{
        sampleLoopSeconds = $clock.Elapsed.TotalSeconds
        frameCounterSeconds = $frameElapsedSeconds
        frameBoundaryMethod = 'request-midpoint'
        processCpu = @($processRows | ForEach-Object { [pscustomobject]@{ pid = $_.pid; elapsedSeconds = $_.elapsedSeconds } })
    }
    processes = @($processRows)
    samples = @($sampleRows)
}
[IO.File]::WriteAllText($resolvedOutput, ($result | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

$skyrim = @($processRows | Where-Object name -eq 'SkyrimVR' | Select-Object -First 1)
$vrserver = @($processRows | Where-Object name -eq 'vrserver' | Select-Object -First 1)
[pscustomobject][ordered]@{
    ok = $true
    outputPath = $resolvedOutput
    condition = $Condition
    scene = $Scene
    elapsedSeconds = $clock.Elapsed.TotalSeconds
    engineFps = $result.engineFps
    skyrimAverageCores = if ($skyrim.Count) { $skyrim[0].averageCores } else { $null }
    vrserverAverageCores = if ($vrserver.Count) { $vrserver[0].averageCores } else { $null }
} | ConvertTo-Json -Depth 5
