# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repositoryRoot 'skills\static-coc\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\static-coc\references\protocol.md'
$pluginSkill = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\static-coc\SKILL.md'
$pluginProtocol = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\static-coc\references\protocol.md'

foreach ($path in @($sourceSkill, $sourceProtocol, $pluginSkill, $pluginProtocol)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Static COC protocol file is missing: $path"
    }
}
foreach ($pair in @(@($sourceSkill, $pluginSkill), @($sourceProtocol, $pluginProtocol))) {
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Static COC package content is stale.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw
foreach ($required in @(
    'start static coc',
    'qualification_wait',
    'strict',
    'timeoutMs: 30000',
    'post-dispatch maximum',
    'returns as soon as strict is satisfied',
    'post-wait `status`',
    'VR FPS Stabilizer exclusively owns'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Static COC skill is missing: $required"
    }
}
foreach ($required in @(
    'communityshaders.renderscale',
    '`strict`, `presentation`, and `cleanup`',
    'native-headless Ghidra MCP receipts',
    '`binaryListReady: true`',
    '`list_binaries` MCP call',
    'Do not require PyGhidra or `eval_python` activation',
    'explicit DevBench runtime metadata',
    'reimports the supplied candidate',
    'dump-write',
    'do not retry it',
    '2 + (20 x 5) = 102 steps',
    'qualification_status',
    'qualification_dispatch',
    '`milestone: "strict"`, `timeoutMs: 30000`',
    '`dimensionsMatch` is producer-owned CSX evidence',
    'without calculating, overriding, or repairing it',
    'transition-epoch-filtered `status.preparation`',
    'request-to-prepared',
    'prepared-to-creator',
    'Do not add fixed',
    'qualification_cancel',
    'strict - presentation',
    'Dragonsreach <= 24',
    'Windhelm <= 20'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Static COC protocol is missing: $required"
    }
}
if ($protocol.Contains('120000', [StringComparison]::Ordinal)) {
    throw 'Static COC retains the superseded 120-second waiter deadline.'
}

[pscustomobject]@{
    ok = $true
    strictMilestone = $true
    waiterDeadlineMs = 30000
    serverSteps = 102
    sourceAndPluginMatch = $true
} | ConvertTo-Json
