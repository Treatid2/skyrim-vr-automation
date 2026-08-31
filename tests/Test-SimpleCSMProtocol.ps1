# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repositoryRoot 'skills\simple-csm\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\simple-csm\references\protocol.md'
$pluginSkill = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\simple-csm\SKILL.md'
$pluginProtocol = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\simple-csm\references\protocol.md'
$matrixPath = Join-Path $repositoryRoot 'tools\render-scale-qualification\protocol.v1.json'

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol)
)) {
    foreach ($path in $pair) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Simple CSM protocol file is missing: $path"
        }
    }
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Simple CSM package content is stale.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw
$matrixProtocol = Get-Content -LiteralPath $matrixPath -Raw |
    ConvertFrom-Json -Depth 20

foreach ($required in @(
    'name: simple-csm',
    'command `simple csm`',
    '../simple-coc/SKILL.md',
    '../simple-coc/references/protocol.md',
    '../../tools/render-scale-qualification/protocol.v1.json',
    'one positioning COC to `WhiterunDragonsreach`',
    '25 exact render-scale `apply` mutations',
    'Setup must not change upscaling'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple CSM skill is missing: $required"
    }
}

foreach ($required in @(
    'exactly 25 Community Shaders menu applies',
    '`coc WhiterunDragonsreach`',
    'Do not query the profiler service or reset telemetry',
    'after exact-cell verification',
    'measurement-admission schema refresh',
    'measurement-admission CPU/GPU reset',
    '{ "wait": 5000 }',
    '`timeoutMs: 30000`',
    '`startPerformanceTelemetry: true` only on transition 1',
    'Do not include `cocCellEditorId`',
    '`dlssPreset: 1`',
    '`dlssProfile: "K"`',
    'Omit `fsrRuntime` from every FSR waiter target',
    'configured FSR runtime preference and physical backend identity as',
    '`desiredBackend`, `authoritativeBackend`',
    '`actualDispatchBackend`',
    '`fsr_host`, `fsr_runtime`, or',
    'AMD hardware',
    'There must be exactly 25 begin, dispatch, apply, waiter, and status',
    'Immediately after transition 25',
    'final scene to remain `WhiterunDragonsreach`',
    'CPU, GPU, lifetime, presentation',
    'resource-publication, preparation-stage',
    'Stop there'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple CSM protocol is missing: $required"
    }
}

foreach ($matrixName in @('nvidiaMatrix', 'amdMatrix')) {
    $matrix = @($matrixProtocol.menuAssay.$matrixName)
    if ($matrix.Count -ne 25) { throw "$matrixName does not contain exactly 25 entries." }
    if ((@($matrix.ordinal) -join ',') -ne ((1..25) -join ',')) {
        throw "$matrixName ordinals are not exactly 1 through 25."
    }
    if ([string]$matrix[-1].method -ne 'fsr' -or
        [string]$matrix[-1].qualityMode -ne 'hoshipa') {
        throw "$matrixName does not end at canonical FSR Hoshipa."
    }
}

$nvidiaMethods = @($matrixProtocol.menuAssay.nvidiaMatrix.method | Sort-Object -Unique)
if (($nvidiaMethods -join ',') -ne 'dlss,fsr') {
    throw 'NVIDIA matrix must retain both DLSS and FSR.'
}
if (@($matrixProtocol.menuAssay.amdMatrix | Where-Object method -ne 'fsr').Count -ne 0) {
    throw 'AMD matrix must remain FSR-only.'
}

[pscustomobject][ordered]@{
    ok = $true
    trigger = 'simple csm'
    initialCell = 'WhiterunDragonsreach'
    measuredTransitions = 25
    pacingMs = 5000
    qualificationTimeoutMs = 30000
    sourceAndPluginMatch = $true
} | ConvertTo-Json
