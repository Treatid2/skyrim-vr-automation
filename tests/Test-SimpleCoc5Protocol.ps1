# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$baseProtocol = Join-Path $repositoryRoot 'skills\simple-coc\references\protocol.md'
$sourceSkill = Join-Path $repositoryRoot 'skills\simple-coc-5\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\simple-coc-5\references\protocol.md'
$pluginSkill = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc-5\SKILL.md'
)
$pluginProtocol = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc-5\references\protocol.md'
)

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol)
)) {
    foreach ($path in $pair) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Simple COC 5 protocol file is missing: $path"
        }
    }
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Simple COC 5 package content is stale.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw
$base = Get-Content -LiteralPath $baseProtocol -Raw

foreach ($required in @(
    'name: simple-coc-5',
    'exact user',
    'command `simple coc 5`',
    '../simple-coc/SKILL.md',
    '../simple-coc/references/protocol.md',
    'only the deliberate pacing wait',
    'Never interpret'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC 5 skill is missing: $required"
    }
}

foreach ($required in @(
    'every one of the 20 measured transition blocks',
    '{ "wait": 5000 }',
    '{ "wait": 10000 }',
    'initial Windhelm positioning stabilization remains 10,000 ms',
    'qualification timeout remains 30,000 ms',
    'do not add another',
    '5,000 ms is the deliberate post-qualification pacing delay'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC 5 timing override is missing: $required"
    }
}

if (-not $base.Contains('{ "wait": 10000 }', [StringComparison]::Ordinal)) {
    throw 'Base Simple COC pacing was changed instead of adding a variant.'
}
if ($base.Contains('{ "wait": 5000 }', [StringComparison]::Ordinal)) {
    throw 'Base Simple COC unexpectedly contains five-second pacing.'
}

[pscustomobject][ordered]@{
    ok = $true
    trigger = 'simple coc 5'
    measuredTransitions = 20
    pacingMs = 5000
    qualificationTimeoutMs = 30000
    baseProtocolUnchanged = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
