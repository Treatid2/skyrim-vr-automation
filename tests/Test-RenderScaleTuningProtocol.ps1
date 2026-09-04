# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Content, [string]$Token, [string]$Context) {
    $normalizedContent = [regex]::Replace($Content, '\s+', ' ')
    $normalizedToken = [regex]::Replace($Token, '\s+', ' ')
    Assert-True $normalizedContent.Contains(
        $normalizedToken,
        [StringComparison]::Ordinal
    ) "$Context is missing: $Token"
}

function Assert-Profile(
    [object]$Destination,
    [string]$Method,
    [string]$Quality,
    [bool]$RenderScale,
    [string]$Context
) {
    Assert-True ($Destination.method -eq $Method) "$Context method is wrong."
    Assert-True ($Destination.qualityMode -eq $Quality) "$Context quality is wrong."
    Assert-True ([bool]$Destination.renderScaleMode -eq $RenderScale) "$Context render-scale flag is wrong."
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$legacyRoots = @(
    (Join-Path $repositoryRoot 'skills\renderscale-tuning'),
    (Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\renderscale-tuning')
)
foreach ($legacyRoot in $legacyRoots) {
    Assert-True (-not (Test-Path -LiteralPath $legacyRoot)) "Legacy generic tuning protocol remains: $legacyRoot"
}

$fastStartRelative = 'docs\protocols\renderscale-tuning-fast-start.md'
$fastStartSource = Join-Path $repositoryRoot $fastStartRelative
$fastStartPlugin = Join-Path $repositoryRoot "plugins\skyrim-vr-automation\$fastStartRelative"
Assert-True (Test-Path -LiteralPath $fastStartSource -PathType Leaf) 'Missing shared tuning fast-start contract.'
Assert-True (Test-Path -LiteralPath $fastStartPlugin -PathType Leaf) 'Missing packaged tuning fast-start contract.'
Assert-True ((Get-FileHash -LiteralPath $fastStartSource -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $fastStartPlugin -Algorithm SHA256).Hash) 'Shared tuning fast-start source/package parity failed.'
$fastStart = Get-Content -LiteralPath $fastStartSource -Raw
Assert-Contains $fastStart 'Pass the positioning receipt unchanged' 'Shared tuning fast-start contract'
Assert-Contains $fastStart 'The client does not search, normalize, or validate positioning' 'Shared tuning fast-start contract'
Assert-True (-not $fastStart.Contains('Pass the initial boundary already decoded during positioning', [StringComparison]::Ordinal)) 'Shared tuning fast-start still delegates boundary decoding to the client.'
$runnerRelative = 'tools\renderscale-tuning-live\runner.js'
$runnerSource = Join-Path $repositoryRoot $runnerRelative
$runnerPlugin = Join-Path $repositoryRoot "plugins\skyrim-vr-automation\$runnerRelative"
Assert-True (Test-Path -LiteralPath $runnerSource -PathType Leaf) 'Missing deterministic tuning runner.'
Assert-True (Test-Path -LiteralPath $runnerPlugin -PathType Leaf) 'Missing packaged deterministic tuning runner.'
Assert-True ((Get-FileHash -LiteralPath $runnerSource -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $runnerPlugin -Algorithm SHA256).Hash) 'Deterministic tuning runner source/package parity failed.'
$runner = Get-Content -LiteralPath $runnerSource -Raw
$finalizerRelative = 'tools\renderscale-tuning-finalizer\finalizer.js'
$finalizerSource = Join-Path $repositoryRoot $finalizerRelative
$finalizerPlugin = Join-Path $repositoryRoot "plugins\skyrim-vr-automation\$finalizerRelative"
Assert-True (Test-Path -LiteralPath $finalizerSource -PathType Leaf) 'Missing shared tuning finalizer.'
Assert-True (Test-Path -LiteralPath $finalizerPlugin -PathType Leaf) 'Missing packaged shared tuning finalizer.'
Assert-True ((Get-FileHash -LiteralPath $finalizerSource -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $finalizerPlugin -Algorithm SHA256).Hash) 'Shared tuning finalizer source/package parity failed.'
$finalizer = Get-Content -LiteralPath $finalizerSource -Raw
foreach ($token in @(
    'async function collectTracePages', 'afterSequence', 'moreAvailable',
    'requestedSequenceOverwritten', 'trace_sequence_gap',
    'trace_sequence_duplicate', 'trace_session_changed',
    'trace_build_changed', 'function finalizeEvidence',
    'missing_required_mutation_boundary', 'phaseCountersAuthoritative',
    'assayExecution', 'task2Evidence', 'reportingStatus',
    'function evidenceValues', 'evidence-values.csv',
    'rfc6901-json-pointer-long-form-csv',
    'evidence_numeric_value_not_lossless', 'delete summary.overallVerdict',
    'per_transition', 'dispatch_left_generation',
    'phaseCounterAuthorityStatus', 'reportedTask2Violations',
    'producer_invalid_evidence', 'deploymentVerification',
    'deployment-verification.json', 'artifact-path', 'manifest-path',
    'nonStableNote', 'stabilityNotes', 'stability_presentation_disposition',
    'recoveryStatus', 'recovery_receipt_key', 'source_recovery_receipt_key'
)) {
    Assert-Contains $finalizer $token 'Shared tuning finalizer'
}
foreach ($token in @(
    'async function runRenderScaleTuningLive',
    'mcp__devbench_vr__scenario',
    'mcp__devbench_vr__communityshaders_renderscale',
    'positioningRoot', 'positioningInputs', 'capabilities',
    'positioning_tool_result_missing', 'positioning_scene_mismatch',
    'Object.prototype.hasOwnProperty.call(entry, "result")',
    'waiter.upscalingSnapshot', 'snapshot.effective',
    'snapshot.profiles && snapshot.profiles.effective',
    'enumName(profile.method)', 'enumName(profile.qualityMode, qualityName)',
    'enumName(profile.dlssProfile)', 'enumName(profile.fsrRuntime)',
    'matrix.pacingMilliseconds', 'matrix.completionTimeoutMilliseconds',
    'startPerformanceTelemetry: firstRow',
    'const retainedKey =', 'retain(retainedKey, retained)',
    'action: "dlss_trace_read"', 'traceReset:', 'traceStart:', 'traceRead:',
    'retainAmdTraceCapability', 'amd:dlss-trace-capability',
    'transitionProjection', 'waiter.cleanupDrained === true',
    'scenarioDiagnostic', 'scenarioReceiptKey', 'failedStep',
    'firstUnreportedStep', 'phaseCounterAuthorityStatus',
    'reportedInvariantViolations', 'violationAuthority', 'boundaryOrder',
    'transitionEvidenceComplete', 'authoritative_violation_schema',
    'retainLiveResult', 'receiptKeys',
    'optionalSafetyFactClear', '"apiOperationClear"',
    '"physicalMutationClear"', 'safeTerminalAssessment',
    'terminal_not_clear', 'recoveryAssessment', 'failureSnapshot',
    'waitArgs.foveation = foveation',
    'for (const row of matrix.transitions)', 'notify({',
    'function nonStableNote', 'status: "not_stable"',
    'restoreBaseline', 'recovery-profile-apply',
    'transition_recovery_failed', 'recoveryReceiptKey'
)) {
    Assert-Contains $runner $token 'Deterministic tuning runner'
}
foreach ($forbidden in @(
    'Get-ChildItem', 'Invoke-RestMethod', '127.0.0.1',
    'mcp__devbench_vr__communityshaders_upscaling_api',
    'sourceDescribe', 'artifactSha256', 'positionBoundary'
)) {
    Assert-True (-not $runner.Contains($forbidden, [StringComparison]::Ordinal)) "Deterministic tuning runner adds an unnecessary live gate: $forbidden"
}
foreach ($token in @(
    'detailed contract', 'packaged deterministic runner and matrix',
    'only after a pass has', 'finalization-only', 'synchronous',
    '`position-health`', '`position-state`',
    '`position-scene`', '`position-capabilities`', '`position-snapshot`',
    '`position-renderscale`', '`cell.editorId: WhiterunDragonsreach`',
    'reports positioning as soon as it admits the response',
    'create an evidence directory', 'decode Base64',
    '`content[0].text`', 'recursively search',
    'without another model handoff',
    'run-unique startup keys', '`raw/startup`',
    '`startup_evidence_incomplete`',
    'forbid the comparison-ledger append',
    'Every later mutation and ownership scenario remains synchronous',
    'terminal baseline waiter receipt', '`milestoneTimings`',
    '`replacementTimeline`', 'Fast measured-loop contract',
    'terminal `qualification-wait` receipt is the transition boundary',
    'Do not invent another previous-transition safety gate',
    '60,000 ms `position-settle`', '20,000 ms strict waiter',
    'record `nonStableNote`', 'not permission to overlap mutations',
    '`store()` that exact terminal receipt', 'return only a compact', '`text()`',
    'Store the complete scenario envelope', '`failedStep`',
    '`firstUnreportedStep`', 'never invent that it failed',
    'complete measured pass in that one live orchestration cell',
    '`notify()`', '`yield_control()`',
    'sole server-owned `wait` of exactly 5,000 ms',
    "preceding terminal waiter's", 'At pass finalization', '`load()`',
    'one cumulative evidence-read batch', 'generate the receipt index',
    '`continueOnError: true`', 'validate each labeled result independently',
    'unsupported optional operation', 'must not suppress',
    'after every interrupted pass', '`tooling_false_positive`',
    'row was never dispatched',
    'read `qualification_status` once'
)) {
    Assert-Contains $fastStart $token 'Shared tuning fast-start contract'
}
foreach ($token in @(
    'post-measurement finalizer', '`evidence-values.csv`',
    'RFC 6901 JSON Pointer', 'Do not use a field allowlist',
    'explicit empty arrays/objects', 'Keep Task 2 classifications per transition',
    'never calculate an aggregate Task 2 or overall verdict',
    'Omit legacy aggregate verdict fields',
    'does not add or reorder startup'
)) {
    Assert-Contains $fastStart $token 'Shared post-measurement extraction contract'
}
foreach ($token in @('six labeled tool steps in this exact order', '`baseline-stress-reset`', '`baseline-stress-start`', '`qualification-begin`', '`qualification-dispatch`', '`profile-apply`', '`qualification-wait`', 'only pre-baseline reset', 'inside the same server-owned scenario', '"timeoutMs":20000', '`timeoutMs: 20000`', 'Do not inspect, validate, persist, or comment', '`stepsRun: 6`', '`results[]` entry `label: profile-apply`', '`result.apply.disposition.name`', '`label: qualification-wait`', '`result.action: qualification_wait`', 'Never search another wrapper location', 'containing scenario response is lost', 'do not replay the scenario, apply, or waiter', 'allow the already-running server scenario', 'at most five additional seconds', 'matching terminal `lastEvidence`', 'Never reapply the profile', 'applies to every baseline and measured waiter', 'must never invoke this handoff scenario', 'handoff scenario is never a cleanup path', 'reset then start texture-lifetime', 'reset then start load-presentation', '"action":"clear_history"', 'do not use', '`start_capture`', 'sole CPU/GPU reset/start', 'Stop only the baseline stress session', 'do not run another local command', 'never search for it', '`communityshaders.profiler_api`', '`result.status.session.id`', 'Immediately begin transition 1')) {
    Assert-Contains $fastStart $token 'Shared server-owned waiter contract'
}
foreach ($token in @(
    '`transitionId` is the only',
    '`ownerId`, `clientId`, and `commandId` are always',
    '`"rst-nvidia-baseline-pass-1-owner"`',
    '"ownerId":"<owner-id>"',
    '"clientId":"<client-id>"',
    '"commandId":"<command-id>"',
    '`cell.editorId: WhiterunDragonsreach`',
    'scene receipt alone owns exact cell identity'
)) {
    Assert-Contains $fastStart $token 'Shared typed positioning/baseline contract'
}
foreach ($forbidden in @(
    'Before the first live request, create one unique evidence root',
    'first action turn after reading this contract must start evidence',
    'create a unique evidence root named',
    'Query profiler `registry` and `snapshot` together as one parallel read-only',
    'Run the one-step negative profiler scenario',
    'with only the remaining portion of the single 30,000',
    'Start a local monotonic startup budget with the first live request',
    'The positioning scenario must be accepted within 30,000 ms',
    'fresh monotonic `positioningDispatchElapsedMs` budget',
    'direct `ping`, `inspect health`',
    '`capabilities`, `snapshot`, and `communityshaders.renderscale status`',
    'Require the runtime-only FOV/TAA `0.3/0.3/0.7` fixture,',
    'render-scale tool description to advertise independent',
    'generic process inventory, adapter description string, or upscaling API receipt is authoritative',
    'one local evidence action before `prepare_coc`',
    '`startupReadElapsedMs`',
    '`positioningDispatchElapsedMs`',
    '`slow_startup_reads`',
    '`slow_positioning_dispatch`',
    'parallel five-read',
    'parallel three-read',
    '`async: true`',
    'positioning-acceptance receipt',
    'during its mandatory 10,000 ms settle',
    '`menu list`',
    '`cpu_performance_reset`',
    '`gpu_performance_reset`',
    'profiler `clear_history`',
    'Reissue the identical `qualification_wait` once immediately',
    '`qualification_wait_active`',
    'Then read the selected matrix, vendor protocol, and this contract completely'
)) {
    Assert-True (-not $fastStart.Contains($forbidden, [StringComparison]::Ordinal)) "Shared tuning fast-start retains an invalid admission rule: $forbidden"
}

$variants = @(
    [pscustomobject]@{
        Name = 'renderscale-tuning-nvidia'
        Trigger = '`renderscale-tuning nvidia`'
        Count = 33
        MeasuredApplyCount = 66
        Sequence = @(
            'none', 'taa', 'dlaa', 'dlss_hoshipa', 'dlss_ultra_quality',
            'dlss_quality', 'dlss_balanced', 'dlss_performance',
            'dlss_ultra_performance', 'dlaa', 'taa', 'none',
            'fsr_native_aa', 'fsr_hoshipa', 'fsr_ultra_quality', 'fsr_quality',
            'fsr_balanced', 'fsr_performance', 'fsr_ultra_performance',
            'fsr_native_aa', 'taa', 'none', 'dlaa', 'fsr_native_aa',
            'dlss_hoshipa', 'fsr_hoshipa', 'none', 'fsr_ultra_performance',
            'dlss_ultra_performance', 'taa', 'fsr_native_aa', 'none', 'dlaa'
        )
    },
    [pscustomobject]@{
        Name = 'renderscale-tuning-amd'
        Trigger = '`renderscale-tuning amd`'
        Count = 31
        MeasuredApplyCount = 62
        Sequence = @(
            'none', 'taa', 'fsr_native_aa', 'fsr_hoshipa',
            'fsr_ultra_quality', 'fsr_quality', 'fsr_balanced',
            'fsr_performance', 'fsr_ultra_performance', 'fsr_native_aa',
            'taa', 'none', 'fsr_hoshipa', 'fsr_native_aa', 'none',
            'fsr_quality', 'taa', 'fsr_balanced', 'none', 'fsr_performance',
            'fsr_native_aa', 'taa', 'fsr_ultra_performance', 'none',
            'fsr_native_aa', 'fsr_hoshipa', 'taa', 'none', 'fsr_native_aa',
            'fsr_ultra_performance', 'fsr_hoshipa'
        )
    }
)

foreach ($variant in $variants) {
    $sourceRoot = Join-Path $repositoryRoot "skills\$($variant.Name)"
    $pluginRoot = Join-Path $repositoryRoot "plugins\skyrim-vr-automation\skills\$($variant.Name)"
    foreach ($relative in @(
        'SKILL.md', 'references\live-fast-path.md',
        'references\protocol.md', 'references\matrix.v1.json'
    )) {
        $source = Join-Path $sourceRoot $relative
        $plugin = Join-Path $pluginRoot $relative
        Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "Missing source file: $source"
        Assert-True (Test-Path -LiteralPath $plugin -PathType Leaf) "Missing package file: $plugin"
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $pluginHash = (Get-FileHash -LiteralPath $plugin -Algorithm SHA256).Hash
        Assert-True ($sourceHash -eq $pluginHash) "$($variant.Name) source/package parity failed for $relative"
    }

    $skill = Get-Content -LiteralPath (Join-Path $sourceRoot 'SKILL.md') -Raw
    $live = Get-Content -LiteralPath (Join-Path $sourceRoot 'references\live-fast-path.md') -Raw
    $protocol = Get-Content -LiteralPath (Join-Path $sourceRoot 'references\protocol.md') -Raw
    $protocolContract = "$skill`n$live`n$fastStart`n$protocol"
    $matrix = Get-Content -LiteralPath (Join-Path $sourceRoot 'references\matrix.v1.json') -Raw | ConvertFrom-Json -Depth 30

    Assert-Contains $skill "name: $($variant.Name)" $variant.Name
    Assert-Contains $skill $variant.Trigger $variant.Name
    Assert-Contains $skill "exactly $($variant.MeasuredApplyCount) measured" $variant.Name
    Assert-Contains $skill 'alter Simple CSM''s 25-step matrix.' $variant.Name
    Assert-Contains $skill 'communityshaders.upscaling_api' $variant.Name
    Assert-Contains $skill 'does not authorize' $variant.Name
    Assert-Contains $skill 'VR FPS Stabilizer' $variant.Name
    Assert-Contains $skill 'outside this assay' $variant.Name
    Assert-Contains $skill 'Direct `mcp__devbench_vr__*` tools are the only' $variant.Name
    Assert-Contains $skill 'Do not enumerate tools or inspect fallbacks' $variant.Name
    Assert-Contains $skill 'if a named tool is not callable' $variant.Name
    Assert-Contains $skill 'never use the bundled controller' $variant.Name
    Assert-True (-not $skill.Contains('evidence-values.csv', [StringComparison]::Ordinal)) "$($variant.Name) moved finalization into startup instructions."
    Assert-Contains $live '../../../docs/protocols/renderscale-tuning-fast-start.md' $variant.Name
    Assert-Contains $skill 'first `mcp__devbench_vr__communityshaders_menu`' $variant.Name
    Assert-Contains $skill '`{"action":"prepare_coc"}`' $variant.Name
    Assert-Contains $skill '"async":false' $variant.Name
    Assert-Contains $skill '"command":"coc WhiterunDragonsreach"' $variant.Name
    Assert-Contains $skill '"label":"position-renderscale"' $variant.Name
    Assert-Contains $skill '"kind":"health"' $variant.Name
    Assert-Contains $skill '"kind":"state"' $variant.Name
    Assert-Contains $skill '"kind":"scene"' $variant.Name
    Assert-Contains $skill 'After the required skill announcement' $variant.Name
    Assert-Contains $skill 'Apart from reading this SKILL' $variant.Name
    Assert-Contains $skill 'one `functions.exec` with nested' $variant.Name
    Assert-Contains $skill 'Never call Scenario first' $variant.Name
    Assert-Contains $skill 'standalone tool' $variant.Name
    Assert-Contains $skill '`startup-prepare`' $variant.Name
    Assert-Contains $skill '`startup-positioning`' $variant.Name
    Assert-Contains $skill '`load()`, compare object identity' $variant.Name
    Assert-Contains $skill 'never correct, restart, or replay' $variant.Name
    Assert-True (-not $skill.Contains('verify both keys with `load()`', [StringComparison]::Ordinal)) "$($variant.Name) still gates startup on stored-object verification."
    Assert-Contains $skill 'finalization materializes both stored responses' $variant.Name
    Assert-Contains $skill '`content[0].type: "text"`' $variant.Name
    Assert-Contains $skill '`JSON.parse`' $variant.Name
    Assert-Contains $skill '`content[0].text`' $variant.Name
    Assert-Contains $protocol '`dlss_trace_status` once' $variant.Name
    Assert-Contains $protocol 'packaged shared render-scale finalizer' $variant.Name
    Assert-Contains $protocol '`tools/renderscale-tuning-finalizer/finalizer.js`' $variant.Name
    Assert-Contains $protocol '`collectTracePages` helper' $variant.Name
    Assert-Contains $protocol '`afterSequence` while `moreAvailable`' $variant.Name
    Assert-Contains $protocol 'rejects gaps, duplicates, overwritten requests' $variant.Name
    Assert-Contains $protocol 'Never supply an invented client limit' $variant.Name
    Assert-Contains $protocol 'restartable from the exact' $variant.Name
    Assert-Contains $protocol '`missing_required_mutation_boundary`' $variant.Name
    Assert-Contains $protocol 'phase counters as non-authoritative' $variant.Name
    Assert-Contains $protocol 'per-transition `task2Evidence`' $variant.Name
    Assert-Contains $protocol '`evidence-values.csv`' $variant.Name
    Assert-Contains $protocol 'RFC 6901 JSON Pointer' $variant.Name
    Assert-Contains $protocol 'Do not use a curated field allowlist' $variant.Name
    Assert-Contains $protocol 'Task 2 is never aggregated into one' $variant.Name
    Assert-Contains $protocol 'Do not calculate an overall verdict' $variant.Name
    foreach ($fixtureToken in @(
        '`ready: true`', '`persisted: false`', '`producer.buildId`',
        '`after.ready`', '`after.vr`', '`after.inGame`',
        '`after.vrFpsStabilizer.activeForSession`',
        '`after.developerMode.active`',
        '`after.developerMode.logLevel: "debug"`',
        '`after.foveation.ready`',
        '`after.foveation.foveatedVendorDispatch`',
        '`after.foveation.peripheryTAAEnable`',
        '`foveatedCenterArea: 0.3`',
        '`peripheryTAACenterArea: 0.3`',
        '`peripheryTAAOuterScale: 0.7`', '`0.000001`'
    )) {
        Assert-Contains $skill $fixtureToken $variant.Name
    }
    Assert-Contains $skill 'No other `before` or `after`' $variant.Name
    Assert-Contains $skill 'do not infer aliases' $variant.Name
    Assert-Contains $skill 'compact positioning `notify()`' $variant.Name
    Assert-Contains $skill '`position-renderscale.result` is an opaque payload' $variant.Name
    Assert-Contains $skill 'no nested `result` or adapter field is required' $variant.Name
    Assert-Contains $skill 'not by another client-side adapter-shape admission gate' $variant.Name
    Assert-True (-not $skill.Contains("Require the structured positioning receipt's bound adapter", [StringComparison]::Ordinal)) "$($variant.Name) still blocks startup on an adapter receipt shape."
    Assert-Contains $skill 'Do not end the positioning `functions.exec`' $variant.Name
    Assert-Contains $skill 'tools/renderscale-tuning-live/runner.js' $variant.Name
    Assert-Contains $skill 'The runner is the executable live contract' $variant.Name
    Assert-Contains $skill 'Do not translate the matrix' $variant.Name
    Assert-Contains $skill 'positioningRoot' $variant.Name
    Assert-Contains $skill 'the runner exclusively owns positioning admission' $variant.Name
    Assert-True (-not $skill.Contains('positioningAdmitted', [StringComparison]::Ordinal)) "$($variant.Name) still calculates client-side positioning admission."
    Assert-True (-not $skill.Contains('hasOwnProperty.call(', [StringComparison]::Ordinal)) "$($variant.Name) still checks positioning payload shape in the client."
    Assert-True (-not $skill.Contains('const initialSnapshot', [StringComparison]::Ordinal)) "$($variant.Name) still decodes the positioning snapshot in the client."
    Assert-True (-not $skill.Contains('const initialBoundary', [StringComparison]::Ordinal)) "$($variant.Name) still constructs a client-side boundary."
    Assert-True (-not $skill.Contains('const capabilities = positioningResults', [StringComparison]::Ordinal)) "$($variant.Name) still inspects capability shape in the client."
    Assert-Contains $skill 'qualification-wait.upscalingSnapshot' $variant.Name
    Assert-Contains $live '`tools/renderscale-tuning-live/runner.js` executes this path' $variant.Name
    Assert-Contains $live 'not read or translated during live measurement' $variant.Name
    Assert-Contains $live 'Do not pause for model reasoning' $variant.Name
    Assert-Contains $live 'Only after a pass completes or is interrupted' $variant.Name
    $firstLiveLine = ($skill.Substring(0, $skill.IndexOf('After the required skill announcement', [StringComparison]::Ordinal)) -split "`n").Count
    Assert-True ($firstLiveLine -le 20) "$($variant.Name) delays its first live instruction."
    Assert-True (-not $skill.Contains('../simple-coc/', [StringComparison]::Ordinal)) "$($variant.Name) still preloads Simple COC."
    Assert-True (-not $skill.Contains('../simple-csm/', [StringComparison]::Ordinal)) "$($variant.Name) still preloads Simple CSM."
    Assert-Contains $skill '"label":"position-settle","wait":60000' $variant.Name
    Assert-True (-not $skill.Contains('"args": { "action": "health" }', [StringComparison]::Ordinal)) "$($variant.Name) uses action instead of kind for inspect health."
    Assert-True (-not $skill.Contains('"args": { "action": "state" }', [StringComparison]::Ordinal)) "$($variant.Name) uses action instead of kind for inspect state."
    Assert-True (-not $skill.Contains('"args": { "action": "scene" }', [StringComparison]::Ordinal)) "$($variant.Name) uses action instead of kind for inspect scene."

    foreach ($token in @(
        '`prepare_coc`', '`0.3/0.3/0.7` fixture',
        '`SKILL.md` owns runtime-only `prepare_coc`, positioning',
        'one synchronous', 'Do not repeat live reads',
        'Do not enumerate', 'audit schemas', '`plugin_direct_unavailable`',
        'no fallback transport',
        'measured live loop before this file is read',
        'deterministic runner in the positioning orchestration cell',
        'Do not reopen, revalidate, or summarize the matrix',
        'reset then start the short', 'six baseline scenario steps',
        'one synchronous fail-closed handoff scenario',
        'coc WhiterunDragonsreach', 'communityshaders.upscaling_api',
        '"expectedStateRevision"', '`clientId`', '`commandId`',
        '`persistence: runtime_only`', 'server-owned 5,000 ms wait',
        '`timeoutMs: 20000`',
        'one shared 20,000 ms monotonic deadline',
        'full dispatch-relative', 'client-side remaining budget',
        'return upon its first successful receipt',
        '`async: false`', 'poll `operation`',
        '`qualification_begin`', '`qualification_dispatch`',
        '`startPerformanceTelemetry: true`', '`qualification_cancel`',
        'continueOnError: false',
        'before the', 'baseline mutation',
        'name` fields only', 'Never submit a raw wrapper object',
        'effective profile''s `name` fields',
        'requested/effective/stable must agree with',
        'No wait, snapshot, client round trip, menu action, or other tool may appear',
        'idempotentReplay: false', '`applied_synchronously`', 'exactly `queued`',
        '`no_change`', 'final scenario `qualification_wait`',
        'waiter subreceipt bypasses handoff',
        'owner-correlated recovery rule immediately',
        'Never replay the', 'terminal `lastEvidence`',
        'bounded recovery assessment', 'diagnostic only',
        'must not', 'change the recovery decision',
        '`method: none`', '`method: taa`', '`qualityMode: 0`',
        'waiter `foveation` field',
        'target-correlated server barrier', 'advancing coherent native presentation',
        '`active/active` native controller state',
        'do not call `qualification_cancel` after any terminal waiter receipt',
        'in the terminal snapshot',
        'recorded transition `FAIL` or `INCONCLUSIVE`',
        'qualification owner closed',
        "lane's existing", 'starting profile',
        'does not retry or revise the failed destination',
        'single reset described above is the only exception',
        'vendor_native', 'same-frame', 'nativeVendorExecution',
        'observation.nativeVendorExecution', 'older producer',
        '`sameFrameBothEyesValid: true`', '`actualBackend`',
        '`actualRuntimeFallbackObserved`', '`dispatchSerial`',
        'resource key remains inactive with backend `none`',
        'Scenario steps cannot interpolate earlier',
        'short ownership sequence', 'Do not issue a separate',
        'atomically resets/starts', '`clear_history`',
        'positioning `communityshaders.renderscale status` result',
        'they are output evidence',
        'Native-generation evidence is optional',
        'do not relabel a core `PASS`',
        'with their exact returned guards',
        'physicalMutationStarted', 'not merely engine-target creator entry',
        'ordinary world frame', 'mixed eye, mixed generation',
        'CPU', 'GPU', 'profiler', 'current/completed/published publication generations',
        'deferred-setup acknowledgement', 'D3D device/context',
        'without protocol-side arithmetic', 'do not calculate',
        'shader-cache waits', 'SSS/SSGI prewarm',
        'DLSS, FSR,', 'request-to-prepared', 'prepared-to-creator',
        'replacement admission state and all reasons', 'consecutive stretch frames',
        '`raw/transitions/', '`receipt-index.json`', 'client response store',
        'compact transition projection',
        '`evidence-values.csv`', 'every scalar, null, and empty container',
        'dispatch, terminal, and first-mutation frame/QPC',
        'diagnostic deltas never',
        '`milestoneTimings`', '`cleanupTailMs`', '`sameObservation`',
        '`replacementTimeline`', '`presentationCycleAudit`',
        '`preparationAdmission: not_applicable`',
        '`replacementMutationAdmission`', '`mutationExpectation`',
        '`MATCHED`, `MISMATCHED`, or', 'reported pipeline observation',
        'Never rewrite a mismatched counter to zero',
        '`dispatch_`', '`blocked_pre_mutation_`', '`last_pre_mutation_`',
        '`first_physical_mutation_`', '`first_post_mutation_`',
        '`first_new_generation_proven_`', '`terminal_`',
        '`physicalMutationStarted`',
        '`selectedPresentationDisposition`', 'relative raw receipt paths plus hashes',
        'only `summary.json` and `transitions.csv` is incomplete',
        'exact matrix twice in the same Skyrim process',
        'exactly one synchronous', 'server-owned 10,000 ms wait',
        'cooldown-start memory snapshot', 'cooldown-end snapshot',
        'Pass 2 transition 1 is the new CPU/GPU timing origin',
        'Do not start a third pass', 'Memory confirmation result',
        '`raw/pass-1/transitions`', '`raw/pass-2/transitions`',
        '`raw/memory`', '`memoryConfirmation`', '`predicateInputs`',
        '`retention_signal`', '`initialization_dominated`',
        '`repeat_not_completed`',
        'Memory growth alone never changes a transition''s',
        '`startup_evidence_incomplete`', '`raw/startup`',
        '`docs/development/vr-render-scale-comparison-ledger.csv`',
        'never search for a',
        'No external', 'Never average'
    )) {
        Assert-Contains $protocolContract $token $variant.Name
    }
    Assert-True (-not $protocol.Contains('communityshaders.menu open', [StringComparison]::Ordinal)) "$($variant.Name) retained menu mutation."
    Assert-True (-not $protocol.Contains('CS-menu-origin render-scale', [StringComparison]::Ordinal)) "$($variant.Name) retained the old render-scale mutation primitive."
    Assert-True (-not $protocol.Contains('SteamVR frame-timing', [StringComparison]::OrdinalIgnoreCase)) "$($variant.Name) retained an external timing comparison."
    Assert-True (-not $protocol.Contains('wait up to 30,000 ms for the public operation', [StringComparison]::Ordinal)) "$($variant.Name) can spend two serial 30-second windows."
    Assert-True (-not $protocol.Contains('Require a complete stable active profile.', [StringComparison]::Ordinal)) "$($variant.Name) still derives public targets from the physical controller projection."
    Assert-True (-not $protocol.Contains('bounded fan-out', [StringComparison]::Ordinal)) "$($variant.Name) still permits concurrent stateful telemetry arming."
    Assert-True (-not $protocol.Contains('stop future mutations, clean up only', [StringComparison]::Ordinal)) "$($variant.Name) still attempts cleanup before prompting on transport loss."
    Assert-True (-not $protocol.Contains('load presentation, CPU/GPU reset', [StringComparison]::Ordinal)) "$($variant.Name) still repeats CPU/GPU reset during initial measured arming."
    Assert-True (-not $protocol.Contains('refresh telemetry schemas', [StringComparison]::Ordinal)) "$($variant.Name) still performs a redundant post-position schema refresh."
    Assert-True (-not $protocol.Contains("controller's short bounded", [StringComparison]::Ordinal)) "$($variant.Name) still ties recovery to a second transport."
    Assert-True (-not $protocol.Contains('Every bundled DevBench controller invocation', [StringComparison]::Ordinal)) "$($variant.Name) still opens a controller per live call."
    Assert-True (-not $protocol.Contains('expected timing-owner cancellation after None/TAA stability', [StringComparison]::Ordinal)) "$($variant.Name) still cancels native qualification instead of using the direct waiter."
    Assert-True (-not $protocol.Contains("deadline's remaining", [StringComparison]::Ordinal)) "$($variant.Name) still passes a client-calculated waiter remainder."
    Assert-True (-not $protocol.Contains('current remaining QPC budget', [StringComparison]::Ordinal)) "$($variant.Name) still passes a current waiter remainder."
    Assert-True (-not $skill.Contains('live public API to expose every action and field', [StringComparison]::Ordinal)) "$($variant.Name) still treats input metadata as an output contract."

    $positioningPosition = $protocol.IndexOf(
        'measured live loop before this file is read',
        [StringComparison]::Ordinal
    )
    $baselinePosition = $protocol.IndexOf(
        'authoritative post-position API snapshot',
        [StringComparison]::Ordinal
    )
    Assert-True ($positioningPosition -ge 0 -and
        $baselinePosition -gt $positioningPosition) "$($variant.Name) baseline does not follow positioning."

    Assert-True ($matrix.schemaVersion -eq 1) "$($variant.Name) schema version is wrong."
    Assert-True ($matrix.protocol -eq $variant.Name) "$($variant.Name) matrix identity is wrong."
    Assert-True ($matrix.pacingMilliseconds -eq 5000) "$($variant.Name) pacing is wrong."
    Assert-True ($matrix.completionTimeoutMilliseconds -eq 20000) "$($variant.Name) timeout is wrong."
    Assert-True ([int]$matrix.traceReadLimit -gt 0) "$($variant.Name) trace read limit is invalid."
    Assert-True (@($matrix.transitions).Count -eq $variant.Count) "$($variant.Name) transition count is wrong."
    $ordinals = @($matrix.transitions | ForEach-Object ordinal)
    Assert-True (($ordinals -join ',') -eq ((1..$variant.Count) -join ',')) "$($variant.Name) ordinals are not contiguous."
    $actualSequence = @($matrix.transitions | ForEach-Object destination)
    Assert-True (($actualSequence -join ',') -eq ($variant.Sequence -join ',')) "$($variant.Name) sequence differs from the canonical matrix."
    foreach ($destination in $actualSequence) {
        Assert-True ($null -ne $matrix.destinations.$destination) "$($variant.Name) references unknown destination $destination."
    }

    Assert-Profile $matrix.destinations.none 'none' 'native_aa' $false "$($variant.Name) None"
    Assert-Profile $matrix.destinations.taa 'taa' 'native_aa' $false "$($variant.Name) TAA"
    foreach ($property in $matrix.destinations.PSObject.Properties) {
        $destination = $property.Value
        if ($destination.completionClass -eq 'vendor_scaled') {
            Assert-True ($destination.renderScaleMode -eq $true) "$($variant.Name) scaled destination is not enabled: $($property.Name)"
            Assert-True ($destination.qualityMode -ne 'native_aa') "$($variant.Name) scaled destination uses native AA: $($property.Name)"
        }
        if ($destination.completionClass -eq 'vendor_native') {
            Assert-True ($destination.renderScaleMode -eq $false) "$($variant.Name) native vendor destination is scaled: $($property.Name)"
            Assert-True ($destination.qualityMode -eq 'native_aa') "$($variant.Name) native vendor destination is not native AA: $($property.Name)"
            Assert-True ($destination.method -in @('dlss', 'fsr')) "$($variant.Name) native vendor destination has no vendor method: $($property.Name)"
        }
    }
}

$nvidia = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\renderscale-tuning-nvidia\references\matrix.v1.json') -Raw | ConvertFrom-Json -Depth 30
Assert-True ($nvidia.adapterVendor -eq 'nvidia') 'NVIDIA matrix vendor is wrong.'
Assert-True ($nvidia.initialDestination -eq 'dlss_hoshipa') 'NVIDIA baseline is wrong.'
Assert-True ($nvidia.initialDormantFsrRuntime -eq 'fsr3') 'NVIDIA dormant FSR runtime is wrong.'
Assert-Profile $nvidia.destinations.dlaa 'dlss' 'native_aa' $false 'NVIDIA DLAA'
Assert-Profile $nvidia.destinations.fsr_native_aa 'fsr' 'native_aa' $false 'NVIDIA FSR Native AA'
foreach ($property in $nvidia.destinations.PSObject.Properties | Where-Object { $_.Name -like 'fsr_*' }) {
    Assert-True ($property.Value.fsrRuntime -eq 'fsr3') "NVIDIA FSR destination does not explicitly request FSR3: $($property.Name)"
    Assert-True ((@($property.Value.expectedBackends) -join ',') -eq 'fsr_host,fsr_runtime') "NVIDIA FSR backend contract is wrong: $($property.Name)"
}
$nvidiaProtocol = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\renderscale-tuning-nvidia\references\protocol.md') -Raw
foreach ($token in @(
    'For each DLSS or DLAA transition', 'owned bounded',
    'reset, start, stop, and raw', 'bounded-read',
    'eErrorDuplicatedConstants` is a transition `FAIL`',
    'continue later matrix rows to preserve the error history',
    '`fsr4_runtime` is a failure', 'Include the preserved `dlssProfile.name`',
    'The strict waiter target carries only the active provider setting'
)) {
    Assert-Contains $nvidiaProtocol $token 'NVIDIA adversarial guard'
}
$nvidiaSkill = Get-Content -LiteralPath (Join-Path $repositoryRoot `
    'skills\renderscale-tuning-nvidia\SKILL.md') -Raw
foreach ($token in @(
    'Explicit failed-recovery replay',
    '`transition_recovery_failed`',
    'close only the identified stale non-HUD menu',
    'complete NVIDIA assay with a fresh run ID',
    'at most one replacement attempt'
)) {
    Assert-Contains "$nvidiaSkill`n$nvidiaProtocol" $token 'NVIDIA operator replay guard'
}
Assert-Contains $fastStart `
    'A variant protocol may permit a separate replacement attempt' `
    'Shared operator replay boundary'

$amd = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\renderscale-tuning-amd\references\matrix.v1.json') -Raw | ConvertFrom-Json -Depth 30
Assert-True ($amd.adapterVendor -eq 'amd') 'AMD matrix vendor is wrong.'
Assert-True ($amd.initialDestination -eq 'fsr_hoshipa') 'AMD baseline is wrong.'
Assert-Profile $amd.destinations.fsr_native_aa 'fsr' 'native_aa' $false 'AMD FSR Native AA'
$amdProtocol = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\renderscale-tuning-amd\references\protocol.md') -Raw
Assert-Contains $amdProtocol 'The strict waiter target carries only active `fsrRuntime` for FSR' 'AMD provider target separation'
$lanes = @($amd.lanes)
Assert-True (($lanes.id -join ',') -eq 'explicit_fsr4,explicit_fsr3,fsr4_to_fsr3_fallback') 'AMD lanes are wrong.'
Assert-True ($lanes[0].configuredFsrRuntime -eq 'fsr4' -and (@($lanes[0].expectedBackends) -join ',') -eq 'fsr4_runtime') 'Explicit FSR4 lane is wrong.'
Assert-True ($lanes[1].configuredFsrRuntime -eq 'fsr3' -and (@($lanes[1].expectedBackends) -join ',') -eq 'fsr_host,fsr_runtime') 'Explicit FSR3 lane is wrong.'
Assert-True ($lanes[2].configuredFsrRuntime -eq 'fsr4' -and $lanes[2].requiresDocumentedFsr4UnavailableCondition -and (@($lanes[2].expectedBackends) -join ',') -eq 'fsr_host,fsr_runtime') 'FSR4 fallback lane is wrong.'
$amdProtocol = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\renderscale-tuning-amd\references\protocol.md') -Raw
foreach ($token in @(
    'blocked lane does not prevent',
    'fallback flag',
    'For the first lane, reuse the', 'Before each later lane',
    'exactly one CPU reset and one GPU reset',
    'one bounded DLSS trace capability lifecycle', 'Require zero DLSS dispatch records.',
    'Retain the complete lifecycle envelope',
    'Never corrupt resources'
)) {
    Assert-Contains $amdProtocol $token 'AMD adversarial guard'
}

foreach ($protocol in @(
    [pscustomobject]@{ Name = 'NVIDIA'; Text = $nvidiaProtocol },
    [pscustomobject]@{ Name = 'AMD'; Text = $amdProtocol }
)) {
    $sharedProtocolText = "$($protocol.Text)`n$fastStart"
    foreach ($token in @(
        "installed plugin's direct DevBench MCP tools exclusively",
        'Do not enumerate',
        'audit schemas',
        '`plugin_direct_unavailable`',
        'no fallback transport',
        'without changing the shared 20-second measurement deadline',
        '`qualification_status`',
        'Never replay the',
        'missing terminal evidence',
        'does not by itself make control unsafe',
        'must remain `PASS`',
        '`nativeGenerationEvidence: INCONCLUSIVE`',
        'qualification-terminal row failure is not a producer terminal failure',
        '`NOT RUN`, never `BLOCKED`',
        '`INTERRUPTED`'
    )) {
        Assert-Contains $sharedProtocolText $token "$($protocol.Name) shared waiter/verdict guard"
    }
    foreach ($forbidden in @(
        'controller may be the sole live lane',
        'bundled-controller fallback lane',
        '`-MaxTransientRetries 0`',
        '`requestTimeoutSeconds`',
        'direct `ping` fails its bounded',
        'Call DevBench `upscalingStable`',
        '`-ExpectedProfileJson`',
        'including deferred tools',
        'complete callable tool catalog',
        'direct MCP tool descriptions as the callable action',
        'measurement admission and reset receipts'
    )) {
        Assert-True (-not $protocol.Text.Contains($forbidden, [StringComparison]::Ordinal)) "$($protocol.Name) permits the controller transport: $forbidden"
    }
    foreach ($forbidden in @(
        'Add and rehash their `receipt-index.json` entries before the next apply',
        'Inspect the completed transition before allowing the next apply',
        'Run a synchronous (`async: false`), server-owned 5,000 ms settling scenario',
        'pre_snapshot_transport_unavailable',
        'Do not attempt cleanup until the user explicitly directs it',
        'Missing startup receipts are a non-blocking anomaly',
        '`startup_receipts_not_retained`'
    )) {
        Assert-True (-not $protocol.Text.Contains($forbidden, [StringComparison]::Ordinal)) "$($protocol.Name) retains blocking per-row work: $forbidden"
    }
    foreach ($required in @(
        'preceding strict terminal receipt',
        'exactly 5,000 ms',
        'Do not create per-row files',
        'compact transition projection',
        'write and hash the complete evidence bundle',
        'finalize immediately',
        'Do not demand a second snapshot or status receipt',
        'shared `tooling_false_positive` path',
        'never-dispatched safety rejection',
        'Never retry an admitted or ambiguous request',
        'Keep chat output compact',
        'rather than JSON null',
        'Expose recovered stretch explicitly in every output',
        '`presentationStretchSelected`',
        '`presentationStretchConsecutiveFrames`',
        '`presentationStretchRecovered`',
        '`presentationStretchRecoveryFrame`',
        '`presentationStretchRecoveryElapsedMs`',
        '`presentationStretchAnomalies`',
        'structured `outstandingCleanupDebt` object',
        'never compare that',
        'never hardcode an expected number',
        'anomaly rather than a failure',
        'must place its tool input in `args`',
        'never use `arguments`',
        'This validation is finalization-only',
        '`finalMethod`, `finalQuality`, `finalRenderScaleMode`',
        'CSV `physical_mutation_started` comes only from',
        '`replacementTimeline.firstPhysicalMutation.physicalMutationStarted`',
        'CSV `actual_backend` comes from',
        'must not be JSON null on a `PASS`',
        '`reporting_contract_incomplete`',
        'per-transition `task2Evidence`',
        'Task 2 is never aggregated into one',
        'Always emit the memory table and `memoryConfirmation` object',
        '`verdict: repeat_not_completed`',
        'no leak/retention conclusion is possible'
    )) {
        Assert-Contains $protocol.Text $required "$($protocol.Name) fast measured-loop guard"
    }
}

# Guard the separate protocol explicitly: this change must not absorb or alter
# Simple CSM's canonical 25-step contract.
$simpleCsmSkill = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\simple-csm\SKILL.md') -Raw
$simpleCsmProtocol = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\simple-csm\references\protocol.md') -Raw
$simpleCsmPluginProtocolPath = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\simple-csm\references\protocol.md'
Assert-Contains $simpleCsmSkill 'name: simple-csm' 'Simple CSM regression guard'
Assert-Contains $simpleCsmProtocol 'exactly 25 Community Shaders menu applies' 'Simple CSM regression guard'
Assert-Contains $simpleCsmProtocol 'tools/render-scale-qualification/protocol.v1.json' 'Simple CSM regression guard'
Assert-Contains $simpleCsmProtocol 'short ownership sequence' 'Simple CSM regression guard'
Assert-Contains $simpleCsmProtocol 'measurement-admission CPU/GPU reset' 'Simple CSM regression guard'
Assert-True (-not $simpleCsmProtocol.Contains('one concurrent bounded fan-out', [StringComparison]::Ordinal)) 'Simple CSM permits concurrent stateful telemetry arming.'
Assert-True (-not $simpleCsmProtocol.Contains('reset CPU/GPU telemetry', [StringComparison]::Ordinal)) 'Simple CSM repeats CPU/GPU reset during measured arming.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'skills\simple-csm\references\protocol.md') -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $simpleCsmPluginProtocolPath -Algorithm SHA256).Hash) 'Simple CSM source/package parity failed for telemetry arming.'
Assert-True (-not $simpleCsmProtocol.Contains('renderscale-tuning-nvidia', [StringComparison]::Ordinal)) 'Simple CSM references NVIDIA tuning.'
Assert-True (-not $simpleCsmProtocol.Contains('renderscale-tuning-amd', [StringComparison]::Ordinal)) 'Simple CSM references AMD tuning.'

foreach ($script in @(
    'tests\Test-RenderScaleTuningLiveRunner.js',
    'tests\Test-RenderScaleTuningFinalizer.js'
)) {
    $output = & node (Join-Path $repositoryRoot $script) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$script failed: $($output -join [Environment]::NewLine)"
    }
}

[pscustomobject][ordered]@{
    ok = $true
    protocols = @('renderscale-tuning-nvidia', 'renderscale-tuning-amd')
    nvidiaTransitions = 33
    amdTransitionsPerLane = 31
    amdLanes = 3
    simpleCsmTransitions = 25
    sourceAndPluginMatch = $true
} | ConvertTo-Json -Depth 5
