# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkillPath = Join-Path $repositoryRoot 'skills\coc-stability\SKILL.md'
$sourceProtocolPath = Join-Path $repositoryRoot (
    'skills\coc-stability\references\protocol.md'
)
$pluginSkillPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\coc-stability\SKILL.md'
)
$pluginProtocolPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\coc-stability\references\protocol.md'
)
$sourceEvidencePath = Join-Path $repositoryRoot (
    'tools\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
)
$pluginEvidencePath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\tools\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
)
$sourceRunnerPath = Join-Path $repositoryRoot (
    'tools\coc-stability-control\Invoke-CocStabilityControl.ps1'
)
$pluginRunnerPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\tools\coc-stability-control\Invoke-CocStabilityControl.ps1'
)
$sourceRunnerModulePath = Join-Path $repositoryRoot (
    'tools\coc-stability-control\CocStabilityControl.psm1'
)
$pluginRunnerModulePath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\tools\coc-stability-control\CocStabilityControl.psm1'
)
$sourceConfigPath = Join-Path $repositoryRoot (
    'tools\coc-stability-control\protocol.v1.json'
)
$pluginConfigPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\tools\coc-stability-control\protocol.v1.json'
)

function Assert-Protocol {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$skill = Get-Content -LiteralPath $sourceSkillPath -Raw
$protocol = Get-Content -LiteralPath $sourceProtocolPath -Raw
$runner = Get-Content -LiteralPath $sourceRunnerPath -Raw
$runnerModule = Get-Content -LiteralPath $sourceRunnerModulePath -Raw
$normalizedSkill = [regex]::Replace($skill, '\s+', ' ')

foreach ($requiredSkillText in @(
    'When Skyrim reaches its main menu/load window',
    'start COC protocol',
    'ready to load',
    'Do not issue a COC',
    'The live command grammar is closed',
    'freeze the phase',
    'ask the user what to do',
    'visibly loaded and says `start`',
    'tools/ghidra-mcp-control.ps1',
    'binaryListReady: true',
    'programMatchesExpectation: true',
    'explicit DevBench runtime metadata',
    'reimports a stale managed program',
    'missing_expected_cell',
    'both DevBench and Ghidra MCP tools',
    'harmless call through each',
    'leave Skyrim at the main menu',
    'coc-evidence-control inspect',
    'dump-write',
    'do not retry arm',
    'waits exactly 10 seconds',
    'During that server wait',
    '"action":"prepare_coc"',
    'one monotonic 10-second watchdog',
    'atomic dispatch claim',
    'coc-stability-control run',
    'capture-hang',
    'VR FPS Stabilizer exclusively owns',
    'neither requires nor forbids a post-dispatch profile change',
    'Do not inspect graphics adapters',
    'resolve a winning MO2 file',
    'Multiple adapters or Stabilizer INIs are irrelevant',
    'startPerformanceTelemetry: true',
    'milestone: "strict"',
    'timeoutMs: 30000',
    'post-dispatch maximum',
    'waiter returns as soon',
    'cleanup-tail aggregates',
    '`status.preparation` trace',
    'prepared-to-creator timings',
    'continueOnError: false',
    'actual failed tool step',
    'make no further main-thread calls'
)) {
    Assert-Protocol $normalizedSkill.Contains(
        $requiredSkillText,
        [StringComparison]::Ordinal
    ) "COC skill is missing: $requiredSkillText"
}

foreach ($requiredProtocolText in @(
    '## Two-command operator handshake',
    '## Literal operator-command contract',
    'closed grammar',
    'blocked awaiting user direction',
    'ask one concise question',
    'ask the user to restart Codex',
    'It authorizes only readiness',
    'Do not issue a console command',
    'second command is `start`',
    'this readiness report does not authorize any game command',
    '## Main-menu Codex and evidence readiness',
    'tools/ghidra-mcp-control.ps1',
    'listenerOwnedBySession: true',
    'binaryListReady: true',
    'programMatchesExpectation: true',
    'controller-recorded imported SHA-256',
    'artifactPath',
    'reimports the supplied candidate',
    'list_binaries',
    'missing_expected_cell',
    'stepsRun:1',
    'exclusively owns the persistent headless',
    'In one parallel local setup group',
    '-TargetPid <exact Skyrim PID>',
    'both DevBench and Ghidra',
    'both game-owned DevBench and Ghidra endpoints',
    'harmless MCP call fails',
    'arm ProcDump',
    'No collector is expected in that blocked state',
    '## Fast start-cell establishment',
    'immediately queue one',
    'Queue that deadline before identity',
    '"wait": 10000',
    '"waitUntil": "playerLoaded", "timeoutMs": 20000',
    'never postpone the scheduled COC',
    '## One-time post-load fixture gate',
    '"action": "prepare_coc"',
    'raises an `info` or less-verbose CSX log level to `debug`',
    'A returned semantic fixture defect',
    'full error history',
    '## Bounded parallel baseline',
    'independent monotonic watchdog job',
    'at 10 seconds the watchdog starts it',
    'coc-stability-control run',
    'capture-hang',
    'not permission to delay or cancel',
    '## Atomic diagnostics and measured assay',
    'startPerformanceTelemetry: true',
    '`milestone: "strict"`',
    '`timeoutMs: 30000`',
    'maximum from the dispatch QPC origin',
    '`dimensionsMatch` is producer-owned CSX evidence',
    'without calculating, overriding, or repairing',
    'transition-epoch-filtered',
    'shader-cache',
    'request-to-prepared latency',
    'prepared-to-creator latency',
    '## Milestone receipt analysis',
    'presentationStable',
    'cleanupDrained',
    'strictSatisfied',
    'outstandingCleanupDebt',
    'strictElapsedFrames',
    'exact `cocCellEditorId`',
    'no separate console action is permitted',
    'Do not issue separate',
    'continueOnError: false',
    'normal tool receipts',
    'actual failed tool step abort',
    '## Hard control failure and immediate analysis',
    'issue no more console, menu, qualification',
    'safe to quit Skyrim only after',
    'gpu_performance_stop',
    'Call it exactly once',
    'Never call',
    'communityshaders.renderscale',
    'Do not enumerate graphics adapters',
    'inspect or compare Stabilizer INIs',
    'running public CSX profile is the sole observation source',
    'must not delay the watchdog or measured scenario'
)) {
    Assert-Protocol $protocol.Contains(
        $requiredProtocolText,
        [StringComparison]::Ordinal
    ) "COC protocol is missing: $requiredProtocolText"
}

$handshakePosition = $protocol.IndexOf(
    '## Two-command operator handshake',
    [StringComparison]::Ordinal
)
$readinessPosition = $protocol.IndexOf(
    '## Main-menu Codex and evidence readiness',
    [StringComparison]::Ordinal
)
$startPosition = $protocol.IndexOf(
    '## Fast start-cell establishment',
    [StringComparison]::Ordinal
)
$fixturePosition = $protocol.IndexOf(
    '## One-time post-load fixture gate',
    [StringComparison]::Ordinal
)
$baselinePosition = $protocol.IndexOf(
    '## Bounded parallel baseline',
    [StringComparison]::Ordinal
)
$assayPosition = $protocol.IndexOf(
    '## Atomic diagnostics and measured assay',
    [StringComparison]::Ordinal
)
$failurePosition = $protocol.IndexOf(
    '## Hard control failure and immediate analysis',
    [StringComparison]::Ordinal
)
Assert-Protocol (
    $handshakePosition -ge 0 -and
    $handshakePosition -lt $readinessPosition -and
    $readinessPosition -lt $startPosition -and
    $startPosition -lt $fixturePosition -and
    $fixturePosition -lt $baselinePosition -and
    $baselinePosition -lt $assayPosition -and
    $assayPosition -lt $failurePosition
) 'Handshake, readiness, start, fixture, baseline, assay, and failure phases are out of order.'

$assayText = $protocol.Substring($assayPosition)
Assert-Protocol (-not $assayText.Contains(
    'prepare_coc',
    [StringComparison]::Ordinal
)) 'The measured assay must not invoke or recheck prepare_coc.'
Assert-Protocol (([regex]::Matches(
    $protocol,
    '"action": "prepare_coc"'
)).Count -eq 1) 'The protocol must contain exactly one prepare_coc invocation.'
Assert-Protocol (-not $protocol.Contains(
    'continueOnError: true',
    [StringComparison]::Ordinal
)) 'A hard control failure must abort later COC dispatches.'
Assert-Protocol (([regex]::Matches(
    $protocol.Substring(
        $startPosition,
        $fixturePosition - $startPosition
    ),
    'coc WindhelmExterior01'
)).Count -eq 1) 'The timed start must dispatch exactly one Windhelm COC.'
Assert-Protocol ($runnerModule.Contains(
    'cocCellEditorId = $cell',
    [StringComparison]::Ordinal
)) 'The measured scenario must bind each COC to qualification_dispatch.'
Assert-Protocol ($runnerModule.Contains(
    "action = 'qualification_status'",
    [StringComparison]::Ordinal
)) 'Every transition must confirm qualification ownership server-side.'
Assert-Protocol ($runnerModule.Contains(
    "milestone = 'strict'",
    [StringComparison]::Ordinal
)) 'The measured scenario must use the strict qualification milestone.'
Assert-Protocol ($runnerModule.Contains(
    'Get-CocQualificationAnalysis',
    [StringComparison]::Ordinal
)) 'The controller must provide milestone analysis from the server transcript.'
Assert-Protocol ($runnerModule.Contains(
    'Get-DevBenchRenderScalePreparationTelemetry',
    [StringComparison]::Ordinal
)) 'The controller must normalize the bounded preparation trace.'
Assert-Protocol (-not $runnerModule.Contains(
    "method = 'tools/list'",
    [StringComparison]::Ordinal
)) 'The controller must not rediscover tools during protocol execution.'
Assert-Protocol (-not $runnerModule.Contains(
    "tool = 'console'",
    [StringComparison]::Ordinal
)) 'The measured scenario must not issue a separate console COC step.'
Assert-Protocol ($runner.Contains(
    "state = 'blocked-awaiting-user'",
    [StringComparison]::Ordinal
)) 'A controller blocker must request user direction.'
Assert-Protocol ($runner.Contains(
    'fixtureAnomalies',
    [StringComparison]::Ordinal
)) 'Fixture anomalies must be preserved for the measured assay.'
$watchdogPosition = $runner.IndexOf(
    '$watchdogJob = Start-ThreadJob',
    [StringComparison]::Ordinal
)
Assert-Protocol ($watchdogPosition -ge 0) (
    'The independent deadline watchdog is missing.'
)
Assert-Protocol (-not $runner.Substring(0, $watchdogPosition).Contains(
    '$fixtureAnomalies.Count',
    [StringComparison]::Ordinal
)) 'Fixture anomalies must not block the deadline watchdog dispatch.'
$failureWritePosition = $runner.IndexOf(
    'Write-AtomicJson -Value $stateRecord',
    [StringComparison]::Ordinal
)
$failureThrowPosition = $runner.IndexOf(
    'if (-not $dispatchAccepted)',
    [StringComparison]::Ordinal
)
Assert-Protocol (
    $failureWritePosition -ge 0 -and
    $failureWritePosition -lt $failureThrowPosition -and
    $runner.Contains('dispatchFailure', [StringComparison]::Ordinal)
) 'A rejected scenario must publish its evidence before returning the failure.'
Assert-Protocol (-not $protocol.Contains(
    'Restart Codex after repairing project configuration',
    [StringComparison]::Ordinal
)) 'A readiness block must ask the user before a Codex restart.'

foreach ($pair in @(
    @($sourceSkillPath, $pluginSkillPath, 'COC skill'),
    @($sourceProtocolPath, $pluginProtocolPath, 'COC protocol'),
    @($sourceEvidencePath, $pluginEvidencePath, 'COC evidence controller'),
    @($sourceRunnerPath, $pluginRunnerPath, 'COC stability controller'),
    @($sourceRunnerModulePath, $pluginRunnerModulePath, 'COC stability module'),
    @($sourceConfigPath, $pluginConfigPath, 'COC stability protocol config')
)) {
    $sourceHash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
    $pluginHash = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash
    Assert-Protocol ($sourceHash -eq $pluginHash) "$($pair[2]) package is stale."
}

$manifest = Get-Content -LiteralPath (
    Join-Path $repositoryRoot 'toolset.manifest.json'
) -Raw | ConvertFrom-Json
$evidenceEntry = @($manifest.tools | Where-Object {
    $_.name -eq 'coc-evidence-control'
})
Assert-Protocol ($evidenceEntry.Count -eq 1) (
    'COC evidence controller registration is missing or ambiguous.'
)
Assert-Protocol (
    $evidenceEntry[0].entryPoint -eq
        'tools/coc-evidence-control/Invoke-CocEvidenceControl.ps1'
) 'COC evidence controller entry point is incorrect.'
$runnerEntry = @($manifest.tools | Where-Object {
    $_.name -eq 'coc-stability-control'
})
Assert-Protocol ($runnerEntry.Count -eq 1) (
    'COC stability controller registration is missing or ambiguous.'
)
Assert-Protocol (
    $runnerEntry[0].entryPoint -eq
        'tools/coc-stability-control/Invoke-CocStabilityControl.ps1'
) 'COC stability controller entry point is incorrect.'

[pscustomobject][ordered]@{
    ok = $true
    mainMenuReadinessBeforeLiveStart = $true
    timedStartQueuedFirst = $true
    boundedParallelBaseline = $true
    independentBaselineWatchdog = $true
    firstCocOwnsPerformanceOrigin = $true
    semanticAnomaliesContinue = $true
    hardControlFailuresAbort = $true
    fidelityPredicatePreserved = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
