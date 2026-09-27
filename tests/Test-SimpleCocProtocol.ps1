# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repositoryRoot 'skills\simple-coc\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\simple-coc\references\protocol.md'
$sourceDevBench = Join-Path $repositoryRoot 'skills\devbench-control\SKILL.md'
$sourceForensics = Join-Path $repositoryRoot (
    'skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)
$pluginSkill = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\SKILL.md'
)
$pluginProtocol = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\references\protocol.md'
)
$pluginDevBench = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\devbench-control\SKILL.md'
)
$pluginForensics = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol),
    @($sourceDevBench, $pluginDevBench),
    @($sourceForensics, $pluginForensics)
)) {
    foreach ($path in $pair) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Simple COC protocol file is missing: $path"
        }
    }
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Simple COC package content is stale.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw
$devBench = Get-Content -LiteralPath $sourceDevBench -Raw
foreach ($required in @(
    'Choose exactly one live transport before the first live call',
    'mandatory and',
    'do not run the bundled controller''s `list`',
    'do not create or resolve a controller',
    'Never cross transports to perform a readiness wait',
    'do not start a controller availability'
)) {
    if (-not $devBench.Contains($required, [StringComparison]::Ordinal)) {
        throw "DevBench one-lane contract is missing: $required"
    }
}
foreach ($required in @(
    '`prepare_coc` exactly once as the first stateful call',
    'Before the unmeasured positioning COC',
    'Do not query the profiler service or',
    'After exact-cell positioning',
    'complete measurement',
    'reset each supported lane once in serialized order',
    'Only independent read-only calls may run concurrently',
    'transition 1''s atomic dispatch remains their sole timing origin',
    '`persisted: false`',
    'developer/debug logging',
    'FOV/TAA `0.3/0.3/0.7`',
    'exclusive owner of DLSS and upscaling',
    'transition-filtered preparation events',
    'prepared-to-creator',
    'separate explicit command `frozen Ghidra`'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC skill is missing: $required"
    }
}

foreach ($required in @(
    '"action":"prepare_coc"',
    'as the first',
    'Only independent read-only calls may run concurrently',
    'stateful reset calls one at a time',
    'each exposed trace, lifetime, and probe capture, then pre-arm',
    'measurement-admission CPU/GPU reset',
    'short ownership sequence',
    'do not issue another CPU/GPU reset',
    'never fan out `start`, `reset`, or `set_enabled` calls',
    'run another discovery or reset cycle',
    'exactly one live DevBench transport',
    'plugin-provided direct MCP tools are callable',
    'their exposed tool descriptions as the live schema inventory',
    'Do not run the bundled controller''s `list`',
    'switch transport lanes during the run',
    'Do not generate or edit task-local orchestration scripts',
    'do not open a bundled-controller session',
    'Do not perform any profiler readiness wait before positioning',
    '`-TimeoutSeconds 10`',
    '`-MaxTransientRetries 0`',
    'outer budget and return on its first successful receipt',
    'Do not repeat the positioning COC',
    'capture.requiresEnabled: true',
    '`contractMajor: 1`',
    'but omits only the required `frameCount`',
    '`invalid_field`',
    'stop before the',
    '`set_enabled`',
    '`enabled: true`',
    '`result.state: "running"`',
    'must abort the scenario before',
    'Never reinterpret exposed-but-',
    'Restore the profiler enabled state',
    '`developerMode.active: true`',
    'logging at `debug`',
    'foveated vendor dispatch enabled with center area `0.3`',
    'periphery TAA enabled with center area `0.3` and outer scale `0.7`',
    'must not save settings or change method, quality, preset',
    'begins only at transition 1''s atomic',
    '`status.preparation` trace',
    'request-to-prepared',
    'preparation availability',
    '20 preparation status',
    'scripts/Start-FrozenGhidra.ps1',
    'cryptographic producer identity',
    'programMatchesExpectation: true',
    'with `-pvr`'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC protocol is missing: $required"
    }
}
foreach ($forbidden in @(
    'bounded setup fan-out',
    'reset CPU/GPU telemetry',
    'refresh the live schema inventory exactly once',
    "after the controller's short retry budget"
)) {
    if ($protocol.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Simple COC retains a redundant or concurrent setup rule: $forbidden"
    }
}

$forensics = Get-Content -LiteralPath $sourceForensics -Raw
foreach ($required in @(
    'Starting Ghidra requires an explicit user request',
    "RelativeCachePath = 'SKSE\Plugins\CommunityShaders.dll'",
    "'tools\build_provenance.py'",
    "'CSX-{0}-{1}'",
    'ProjectName = $projectName',
    'programMatchesExpectation'
)) {
    if (-not $forensics.Contains($required, [StringComparison]::Ordinal)) {
        throw "Frozen Ghidra helper is missing: $required"
    }
}

$bindPosition = $protocol.IndexOf(
    '## 1. Bind DevBench and the build',
    [StringComparison]::Ordinal
)
$preparePosition = $protocol.IndexOf(
    '"action":"prepare_coc"',
    [StringComparison]::Ordinal
)
$positioningPosition = $protocol.IndexOf(
    '## 2. Position at Windhelm',
    [StringComparison]::Ordinal
)
if ($bindPosition -lt 0 -or $preparePosition -le $bindPosition -or
    $positioningPosition -le $preparePosition) {
    throw 'Simple COC fixture setup is not inside the DevBench binding phase.'
}

$bindingSection = $protocol.Substring(
    $bindPosition,
    $positioningPosition - $bindPosition
)
foreach ($forbidden in @(
    'communityshaders.profiler_api',
    '`serviceReady`',
    'reset each supported telemetry lane'
)) {
    if ($bindingSection.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Simple COC binding still gates positioning on measurement service: $forbidden"
    }
}
$measurementAdmissionPosition = $protocol.IndexOf(
    'complete this measurement-admission gate',
    [StringComparison]::Ordinal
)
if ($measurementAdmissionPosition -le $positioningPosition) {
    throw 'Simple COC measurement admission must follow positioning.'
}

[pscustomobject][ordered]@{
    ok = $true
    fixtureDuringBinding = $true
    debugLogging = $true
    runtimeOnly = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
