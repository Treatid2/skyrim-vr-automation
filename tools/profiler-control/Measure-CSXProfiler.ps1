# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][string]$ContextJson,
    [ValidateRange(3, 10000)][int]$Samples = 120,
    [ValidateRange(0, 100)][int]$WarmupSamples = 5,
    [ValidateRange(50, 60000)][int]$IntervalMs = 250,
    [ValidateRange(1, 30)][int]$FreshFrameTimeoutSeconds = 5,
    [ValidateRange(5, 3600)][int]$TotalTimeoutSeconds = 300,
    [ValidateRange(1, 120)][int]$RestoreReserveSeconds = 15,
    [ValidateRange(1, 120)][int]$LeaseTimeoutSeconds = 10,
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$DevBenchControlPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$devBenchControlModule = Import-Module (Join-Path $PSScriptRoot '..\devbench-control\DevBenchControl.psm1') -Force -PassThru

function Invoke-DevBenchNormalizer([string]$Name, $Response) {
    $command = $devBenchControlModule.ExportedCommands[$Name]
    if ($null -eq $command) { throw "DevBench normalizer '$Name' is not exported by the central controller module." }
    return & $command -Response $Response
}

function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 80), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -Depth 80
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertTo-CanonicalValue($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable]) { return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ }) }
    $properties = [ordered]@{}
    $names = [string[]]@($Value.PSObject.Properties.Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) { $properties[$name] = ConvertTo-CanonicalValue $Value.$name }
    return $properties
}

function Get-CanonicalHash($Value) {
    $json = (ConvertTo-CanonicalValue $Value) | ConvertTo-Json -Depth 80 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($json)))
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    return [double]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1))]
}

function Get-MetricSummary([double[]]$Values) {
    if ($Values.Count -eq 0) { return [pscustomobject][ordered]@{ count = 0; mean = $null; median = $null; p95 = $null; p99 = $null; min = $null; max = $null } }
    $measure = $Values | Measure-Object -Average -Minimum -Maximum
    return [pscustomobject][ordered]@{
        count = $Values.Count; mean = [double]$measure.Average
        median = Get-Percentile $Values 0.5; p95 = Get-Percentile $Values 0.95; p99 = Get-Percentile $Values 0.99
        min = [double]$measure.Minimum; max = [double]$measure.Maximum
    }
}

function Assert-Finite([double]$Value, [string]$Name) {
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw "Profiler metric '$Name' is not finite." }
}

function Get-ProfilerControlRoot([string]$CanonicalRuntimePath) {
    $override = [string]$env:CSX_PROFILER_CONTROL_ROOT
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $resolvedOverride = [IO.Path]::GetFullPath($override)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not $resolvedOverride.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'CSX_PROFILER_CONTROL_ROOT is fixture-only and must resolve below the operating-system temporary directory.'
        }
        return $resolvedOverride
    }
    $keyBytes = [Text.UTF8Encoding]::new($false).GetBytes($CanonicalRuntimePath.ToUpperInvariant())
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyBytes)).Substring(0, 32).ToLowerInvariant()
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) (Join-Path 'CSX-VR-Automation\profiler-captures' $key)
}

function Acquire-ProfilerLease([string]$ControlRoot, [int]$TimeoutSeconds) {
    if (-not (Test-Path -LiteralPath $ControlRoot -PathType Container)) { New-Item -ItemType Directory -Path $ControlRoot -Force | Out-Null }
    $path = Join-Path $ControlRoot 'capture.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return [pscustomobject][ordered]@{ path = $path; stream = $stream; acquiredUtc = [DateTime]::UtcNow.ToString('o') }
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw [TimeoutException]::new("Timed out waiting for the profiler capture lease: $path") }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Get-StableRuntimeIdentity($Identity) {
    if ($null -eq $Identity -or -not $Identity.complete -or -not $Identity.verified) {
        throw 'Profiler capture requires a complete and verified DevBench runtime identity on every response.'
    }
    return [ordered]@{
        listenerPid = [int]$Identity.listenerPid
        processPath = [string]$Identity.process.path
        processStartTimeUtc = [string]$Identity.process.startTimeUtc
        buildId = [string]$Identity.build.buildId
        artifactPath = [string]$Identity.artifact.path
        artifactSha256 = [string]$Identity.artifact.sha256
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.' }
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
$RuntimePath = [IO.Path]::GetFullPath($RuntimePath)
if ($RestoreReserveSeconds -ge $TotalTimeoutSeconds) { throw 'RestoreReserveSeconds must be smaller than TotalTimeoutSeconds.' }
$context = $ContextJson | ConvertFrom-Json -AsHashtable -Depth 40
if (-not $context.ContainsKey('environment') -or -not ($context.environment -is [Collections.IDictionary])) { throw 'ContextJson requires an environment object.' }
foreach ($required in @('mo2Profile', 'scene', 'hmdMode', 'renderResolution')) {
    if (-not $context.environment.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$context.environment[$required])) { throw "ContextJson environment requires '$required'." }
}
if (-not $context.ContainsKey('treatment')) { $context['treatment'] = [ordered]@{} }

$control = if ([string]::IsNullOrWhiteSpace($DevBenchControlPath)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1' } else { [IO.Path]::GetFullPath($DevBenchControlPath) }
if (-not (Test-Path -LiteralPath $control -PathType Leaf)) { throw "The central DevBench controller is unavailable: $control" }
$transactionId = [guid]::NewGuid().ToString('N')
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = 'capture' }
$runDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) "profiler-$safeLabel-$transactionId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$receiptPath = Join-Path $runDirectory 'capture.receipt.json'
$receipt = [ordered]@{
    schemaVersion = 3; operation = 'measure-profiler'; transactionId = $transactionId; state = 'prepared'
    label = $Label; runtimePath = [IO.Path]::GetFullPath($RuntimePath); context = $context
    preparedUtc = [DateTime]::UtcNow.ToString('o'); priorEnabled = $null; finalEnabled = $null
    totalTimeoutSeconds = $TotalTimeoutSeconds; restoreReserveSeconds = $RestoreReserveSeconds
    stateRestored = $false; restoreErrors = @(); captureError = $null
    runtimeIdentityObservations = @(); performanceObservations = @()
}
Write-JsonAtomic $receiptPath $receipt

$operationDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TotalTimeoutSeconds)
$captureDeadlineUtc = $operationDeadlineUtc.AddSeconds(-$RestoreReserveSeconds)
$expectedRuntimeIdentity = $null
$expectedRuntimeIdentityFingerprint = $null
$performanceGuardInitialized = $false
$expectedPerformanceApplicable = $false
$expectedPerformanceEpoch = $null

function Get-RemainingProfilerSeconds([switch]$ForRestore) {
    $deadline = if ($ForRestore) { $operationDeadlineUtc } else { $captureDeadlineUtc }
    $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -lt 1) {
        $scope = if ($ForRestore) { 'total operation' } else { 'capture phase' }
        throw [TimeoutException]::new("Profiler $scope deadline expired before another DevBench request could start.")
    }
    return [int][Math]::Max(1, [Math]::Min(600, [Math]::Ceiling($remaining)))
}

function Start-ProfilerDelay([int]$RequestedMilliseconds) {
    if ($RequestedMilliseconds -le 0) { return }
    $remaining = [long]($captureDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
    if ($remaining -le 0) { throw [TimeoutException]::new('Profiler capture phase deadline expired before its next delay.') }
    Start-Sleep -Milliseconds ([int][Math]::Min($RequestedMilliseconds, $remaining))
}

function Invoke-ProfilerAction([string]$Action, [switch]$ForRestore) {
    $arguments = @{ action = $Action } | ConvertTo-Json -Compress
    $remainingSeconds = Get-RemainingProfilerSeconds -ForRestore:$ForRestore
    $call = & $control call -Tool 'communityshaders.profiler' -ArgumentsJson $arguments -RuntimePath $RuntimePath -EvidenceDirectory $runDirectory -EvidenceLabel "profiler-$Action" -TimeoutSeconds $remainingSeconds -RequireSuccess -RequirePerformanceNeutral:(-not $ForRestore) -NoExit -Compact | ConvertFrom-Json -Depth 80
    if (-not $ForRestore -and $call.data) {
        $performanceGuard = if ($call.data.PSObject.Properties['performanceGuard']) { $call.data.performanceGuard } else { $null }
        $performanceWindow = if ($call.data.PSObject.Properties['performanceWindow']) { $call.data.performanceWindow } else { $null }
        $script:receipt.performanceObservations = @($script:receipt.performanceObservations) + @([pscustomobject][ordered]@{
            action = $Action
            observedUtc = [DateTime]::UtcNow.ToString('o')
            guard = $performanceGuard
            window = $performanceWindow
            evidencePath = $call.invocationEvidencePath
        })
        if ($null -eq $performanceGuard -or $null -eq $performanceWindow -or -not $performanceWindow.valid) {
            throw "DevBench profiler '$Action' did not preserve a valid performance-neutrality window."
        }
        $applicable = [bool]$performanceGuard.applicable
        $epoch = if ($applicable) { $performanceGuard.performanceEpoch } else { $null }
        if (-not $script:performanceGuardInitialized) {
            $script:performanceGuardInitialized = $true
            $script:expectedPerformanceApplicable = $applicable
            $script:expectedPerformanceEpoch = $epoch
        }
        elseif ($applicable -ne $script:expectedPerformanceApplicable -or
            ($applicable -and [uint64]$epoch -ne [uint64]$script:expectedPerformanceEpoch)) {
            throw "DevBench profiler '$Action' observed a changed performance-probe registration or ownership epoch."
        }
    }
    if (-not $call.ok) { throw "DevBench profiler '$Action' failed: $($call.errors -join '; ')" }
    $payload = @($call.data.content | Where-Object { $null -ne $_ } | Select-Object -First 1)
    if ($payload.Count -ne 1) { throw "DevBench profiler '$Action' returned no structured content." }
    $stableIdentity = Get-StableRuntimeIdentity -Identity $call.runtimeIdentity
    $identityFingerprint = Get-CanonicalHash $stableIdentity
    if ($null -eq $script:expectedRuntimeIdentityFingerprint) {
        $script:expectedRuntimeIdentity = $stableIdentity
        $script:expectedRuntimeIdentityFingerprint = $identityFingerprint
    }
    elseif ($identityFingerprint -cne $script:expectedRuntimeIdentityFingerprint) {
        throw "DevBench runtime identity changed during profiler capture; refusing to mix samples or mutate the replacement runtime. Expected $($script:expectedRuntimeIdentityFingerprint), observed $identityFingerprint."
    }
    $script:receipt.runtimeIdentityObservations = @($script:receipt.runtimeIdentityObservations) + @([pscustomobject][ordered]@{
        action = $Action; observedUtc = [DateTime]::UtcNow.ToString('o'); fingerprint = $identityFingerprint; evidencePath = $call.invocationEvidencePath
    })
    return [pscustomobject][ordered]@{ payload = $payload[0]; runtimeIdentity = $call.runtimeIdentity; stableRuntimeIdentity = $stableIdentity; runtimeIdentityFingerprint = $identityFingerprint; evidencePath = $call.invocationEvidencePath }
}

function Get-ResourcePublicationSnapshot([Parameter(Mandatory)][string]$Phase) {
    $remainingSeconds = Get-RemainingProfilerSeconds
    $call = & $control call -Tool 'communityshaders.renderscale' `
        -ArgumentsJson '{"action":"status"}' -RuntimePath $RuntimePath `
        -EvidenceDirectory $runDirectory -EvidenceLabel "renderscale-$Phase" `
        -TimeoutSeconds $remainingSeconds -RequireSuccess `
        -RequirePerformanceNeutral -NoExit -Compact | ConvertFrom-Json -Depth 80
    if (-not $call.ok) {
        return [pscustomobject][ordered]@{
            phase = $Phase
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            telemetry = Invoke-DevBenchNormalizer 'Get-DevBenchResourcePublicationTelemetry' $null
            preparation = Invoke-DevBenchNormalizer 'Get-DevBenchRenderScalePreparationTelemetry' $null
            invocationEvidencePath = $call.invocationEvidencePath
            error = $call.errors -join '; '
        }
    }

    $stableIdentity = Get-StableRuntimeIdentity -Identity $call.runtimeIdentity
    $identityFingerprint = Get-CanonicalHash $stableIdentity
    if ($identityFingerprint -cne $script:expectedRuntimeIdentityFingerprint) {
        throw "DevBench runtime identity changed during profiler capture; refusing render-scale telemetry from the replacement runtime. Expected $($script:expectedRuntimeIdentityFingerprint), observed $identityFingerprint."
    }
    $payload = @($call.data.content | Where-Object { $null -ne $_ } | Select-Object -First 1)
    if ($payload.Count -ne 1) {
        return [pscustomobject][ordered]@{
            phase = $Phase
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            telemetry = Invoke-DevBenchNormalizer 'Get-DevBenchResourcePublicationTelemetry' $null
            preparation = Invoke-DevBenchNormalizer 'Get-DevBenchRenderScalePreparationTelemetry' $null
            invocationEvidencePath = $call.invocationEvidencePath
            error = 'Render-scale status returned no structured content.'
        }
    }
    return [pscustomobject][ordered]@{
        phase = $Phase
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        telemetry = Invoke-DevBenchNormalizer 'Get-DevBenchResourcePublicationTelemetry' $payload[0]
        preparation = Invoke-DevBenchNormalizer 'Get-DevBenchRenderScalePreparationTelemetry' $payload[0]
        invocationEvidencePath = $call.invocationEvidencePath
        error = $null
    }
}

function Get-ProfilerStatus($Envelope) {
    $payload = $Envelope.payload
    $status = if ($payload.PSObject.Properties['status']) { $payload.status } else { $payload }
    if (-not $status.PSObject.Properties['frame_count']) { throw 'Profiler status omitted frame_count.' }
    return $status
}

function Get-ProfilerEnabled($Status) {
    foreach ($name in @('enabled', 'profilerEnabled', 'active')) {
        if ($Status.PSObject.Properties[$name]) { return [bool]$Status.$name }
    }
    throw 'Profiler status did not report its current enabled state; mutation is not authorized without a restorable preimage.'
}

function Write-ProfilerTransactionJournal([Collections.IDictionary]$Journal) {
    Write-JsonAtomic -Path $authoritativeJournalPath -Value $Journal
    if ($Journal.Contains('evidenceMirrorPath') -and -not [string]::IsNullOrWhiteSpace([string]$Journal.evidenceMirrorPath)) {
        Write-JsonAtomic -Path ([string]$Journal.evidenceMirrorPath) -Value $Journal
    }
}

function Resolve-PendingProfilerTransaction {
    if (-not (Test-Path -LiteralPath $authoritativeJournalPath -PathType Leaf)) { return $null }
    $pending = Get-Content -LiteralPath $authoritativeJournalPath -Raw | ConvertFrom-Json -AsHashtable -Depth 80
    if ([string]$pending.phase -in @('completed', 'rolled-back', 'recovered-preimage', 'recovered-runtime-replaced', 'aborted-before-mutation')) { return $null }
    if (-not $pending.Contains('runtimePath') -or -not [string]::Equals([IO.Path]::GetFullPath([string]$pending.runtimePath), $RuntimePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Profiler recovery journal targets an unexpected runtime metadata file: $authoritativeJournalPath"
    }
    if ($null -eq $pending.priorEnabled) {
        $pending.phase = 'aborted-before-mutation'
        $pending.recoveredUtc = [DateTime]::UtcNow.ToString('o')
        Write-ProfilerTransactionJournal -Journal $pending
        return $pending
    }
    if ([string]::IsNullOrWhiteSpace([string]$pending.runtimeIdentityFingerprint)) {
        throw "Profiler recovery cannot identify the runtime whose state may have changed: $authoritativeJournalPath"
    }

    # Observe first with no inherited expectation. A replacement process owns a distinct
    # in-memory profiler state and must never be toggled to satisfy the dead process.
    $script:expectedRuntimeIdentity = $null
    $script:expectedRuntimeIdentityFingerprint = $null
    $envelope = Invoke-ProfilerAction 'status' -ForRestore
    $observedFingerprint = [string]$envelope.runtimeIdentityFingerprint
    if ($observedFingerprint -cne [string]$pending.runtimeIdentityFingerprint) {
        $pending.phase = 'recovered-runtime-replaced'
        $pending.recoveredUtc = [DateTime]::UtcNow.ToString('o')
        $pending.recovery = [ordered]@{ mutatedReplacement = $false; observedRuntimeIdentityFingerprint = $observedFingerprint }
        Write-ProfilerTransactionJournal -Journal $pending
        return $pending
    }

    $status = Get-ProfilerStatus $envelope
    $enabled = Get-ProfilerEnabled $status
    if ($enabled -ne [bool]$pending.priorEnabled) {
        $null = Invoke-ProfilerAction $(if ([bool]$pending.priorEnabled) { 'enable' } else { 'disable' }) -ForRestore
        $status = Get-ProfilerStatus (Invoke-ProfilerAction 'status' -ForRestore)
        $enabled = Get-ProfilerEnabled $status
    }
    if ($enabled -ne [bool]$pending.priorEnabled) { throw 'Profiler restart recovery could not restore the exact prior enable state.' }
    $pending.phase = 'recovered-preimage'
    $pending.recoveredUtc = [DateTime]::UtcNow.ToString('o')
    $pending.recovery = [ordered]@{ stateRestored = $true; finalEnabled = $enabled; runtimeIdentityFingerprint = $observedFingerprint }
    Write-ProfilerTransactionJournal -Journal $pending
    return $pending
}

$records = [Collections.Generic.List[object]]::new()
$runtimeIdentity = $null
$captureFailure = $null
$resourcePublicationBefore = $null
$resourcePublicationAfter = $null
$startedUtc = [DateTime]::UtcNow
$controlRoot = Get-ProfilerControlRoot -CanonicalRuntimePath $RuntimePath
$authoritativeJournalPath = Join-Path $controlRoot 'transaction.journal.json'
$lease = Acquire-ProfilerLease -ControlRoot $controlRoot -TimeoutSeconds $LeaseTimeoutSeconds
$transactionJournal = $null
try {
    $receipt.leasePath = $lease.path
    $receipt.leaseAcquiredUtc = $lease.acquiredUtc
    $receipt.state = 'leased'
    $receipt.authoritativeJournalPath = $authoritativeJournalPath
    Write-JsonAtomic $receiptPath $receipt
    $recoveredTransaction = Resolve-PendingProfilerTransaction
    if ($recoveredTransaction) {
        $receipt.recoveredTransaction = [ordered]@{ transactionId = [string]$recoveredTransaction.transactionId; phase = [string]$recoveredTransaction.phase; recoveredUtc = [string]$recoveredTransaction.recoveredUtc }
        Write-JsonAtomic $receiptPath $receipt
    }
    $initialEnvelope = Invoke-ProfilerAction 'status'
    $initialStatus = Get-ProfilerStatus $initialEnvelope
    $runtimeIdentity = $initialEnvelope.runtimeIdentity
    $priorEnabled = Get-ProfilerEnabled $initialStatus
    $stableRuntimeIdentity = $initialEnvelope.stableRuntimeIdentity
    $receipt.priorEnabled = $priorEnabled
    $receipt.runtimeIdentity = $runtimeIdentity
    $receipt.stableRuntimeIdentity = $stableRuntimeIdentity
    $receipt.contextFingerprint = Get-CanonicalHash ([ordered]@{ environment = $context.environment; runtimeIdentity = $stableRuntimeIdentity })
    $receipt.treatmentFingerprint = Get-CanonicalHash $context.treatment
    $receipt.state = 'prior-state-recorded'
    Write-JsonAtomic $receiptPath $receipt
    $transactionJournal = [ordered]@{
        contractVersion = '1.0.0'; operation = 'measure-profiler'; transactionId = $transactionId; phase = 'prior-state-recorded'
        runtimePath = $RuntimePath; runtimeIdentityFingerprint = $expectedRuntimeIdentityFingerprint; priorEnabled = $priorEnabled
        evidenceMirrorPath = (Join-Path $runDirectory 'transaction.journal.json'); receiptPath = $receiptPath
        preparedUtc = $receipt.preparedUtc; deadlineUtc = $operationDeadlineUtc.ToString('o'); recovery = $null
    }
    Write-ProfilerTransactionJournal -Journal $transactionJournal
    if (-not $priorEnabled) {
        $transactionJournal.phase = 'enable-dispatch-uncommitted'
        Write-ProfilerTransactionJournal -Journal $transactionJournal
        $null = Invoke-ProfilerAction 'enable'
    }
    $receipt.state = 'sampling'
    $transactionJournal.phase = 'sampling'
    Write-ProfilerTransactionJournal -Journal $transactionJournal
    Write-JsonAtomic $receiptPath $receipt

    $lastFrame = [long]-1
    for ($warmup = 0; $warmup -lt $WarmupSamples; $warmup++) {
        $warmupStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status')
        $lastFrame = [Math]::Max($lastFrame, [long]$warmupStatus.frame_count)
        Start-ProfilerDelay -RequestedMilliseconds $IntervalMs
    }
    $resourcePublicationBefore = Get-ResourcePublicationSnapshot -Phase 'before'
    for ($sampleIndex = 1; $sampleIndex -le $Samples; $sampleIndex++) {
        $candidateFreshDeadline = [DateTime]::UtcNow.AddSeconds($FreshFrameTimeoutSeconds)
        $freshDeadline = if ($candidateFreshDeadline -lt $captureDeadlineUtc) { $candidateFreshDeadline } else { $captureDeadlineUtc }
        do {
            $envelope = Invoke-ProfilerAction 'status'
            $status = Get-ProfilerStatus $envelope
            $frame = [long]$status.frame_count
            if ($frame -gt $lastFrame) { break }
            Start-ProfilerDelay -RequestedMilliseconds ([Math]::Min(50, $IntervalMs))
        } while ([DateTime]::UtcNow -lt $freshDeadline)
        if ($frame -le $lastFrame) { throw "Profiler did not advance beyond frame $lastFrame within $FreshFrameTimeoutSeconds seconds." }
        $resolvedTotal = [double]$status.resolvedTotalMs
        $resolvedCpuTotal = [double]$status.resolvedCpuTotalMs
        Assert-Finite $resolvedTotal 'resolvedTotalMs'
        Assert-Finite $resolvedCpuTotal 'resolvedCpuTotalMs'
        foreach ($timer in @($status.timers)) {
            foreach ($metric in @('gpuMs', 'topLevelMs', 'cpuMs')) {
                if ($timer.PSObject.Properties[$metric]) { Assert-Finite ([double]$timer.$metric) "$($timer.name).$metric" }
            }
        }
        $records.Add([pscustomobject][ordered]@{
            sample = $sampleIndex; timestampUtc = [DateTime]::UtcNow.ToString('o'); frame = $frame
            capturedFrame = [long]$status.capturedFrameCount; resolvedTotalMs = $resolvedTotal; resolvedCpuTotalMs = $resolvedCpuTotal
            acquiredSlots = [int]$status.acquiredSlots; slotRefusals = [int]$status.slotRefusals; timers = @($status.timers)
            invocationEvidencePath = $envelope.evidencePath
            runtimeIdentityFingerprint = $envelope.runtimeIdentityFingerprint
            contextFingerprint = $receipt.contextFingerprint; treatmentFingerprint = $receipt.treatmentFingerprint
        })
        $lastFrame = $frame
        if ($sampleIndex -lt $Samples) { Start-ProfilerDelay -RequestedMilliseconds $IntervalMs }
    }
    $resourcePublicationAfter = Get-ResourcePublicationSnapshot -Phase 'after'
}
catch {
    $captureFailure = $_.Exception.Message
    $receipt.captureError = $captureFailure
}
finally {
    $restoreErrors = [Collections.Generic.List[string]]::new()
    if ($null -ne $receipt.priorEnabled) {
        try {
            if ($transactionJournal) {
                $transactionJournal.phase = 'restore-uncommitted'
                Write-ProfilerTransactionJournal -Journal $transactionJournal
            }
            $finalStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status' -ForRestore)
            $finalEnabled = Get-ProfilerEnabled $finalStatus
            if ($finalEnabled -ne [bool]$receipt.priorEnabled) {
                $null = Invoke-ProfilerAction $(if ($receipt.priorEnabled) { 'enable' } else { 'disable' }) -ForRestore
                $finalStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status' -ForRestore)
                $finalEnabled = Get-ProfilerEnabled $finalStatus
            }
            $receipt.finalEnabled = $finalEnabled
            $receipt.stateRestored = $finalEnabled -eq [bool]$receipt.priorEnabled
            if (-not $receipt.stateRestored) { $restoreErrors.Add('Profiler enable state did not return to its exact prior value.') }
        }
        catch { $restoreErrors.Add($_.Exception.Message) }
    }
    $receipt.restoreErrors = @($restoreErrors)
    $receipt.state = if ($restoreErrors.Count -gt 0) { 'recovery-required' } elseif ($captureFailure) { 'rolled-back' } else { 'completed' }
    if ($transactionJournal) {
        $transactionJournal.phase = [string]$receipt.state
        $transactionJournal.completedUtc = [DateTime]::UtcNow.ToString('o')
        $transactionJournal.finalEnabled = $receipt.finalEnabled
        $transactionJournal.stateRestored = $receipt.stateRestored
        $transactionJournal.restoreErrors = @($restoreErrors)
        Write-ProfilerTransactionJournal -Journal $transactionJournal
    }
    $receipt.completedUtc = [DateTime]::UtcNow.ToString('o')
    $receipt.leaseReleasedUtc = [DateTime]::UtcNow.ToString('o')
    if ($lease -and $lease.stream) { $lease.stream.Dispose() }
    Write-JsonAtomic $receiptPath $receipt
}

if ($receipt.restoreErrors.Count -gt 0) { throw "Profiler capture requires state recovery: $($receipt.restoreErrors -join '; '). Receipt: $receiptPath" }
if ($captureFailure) { throw "$captureFailure Profiler state was restored. Receipt: $receiptPath" }
if ($records.Count -ne $Samples -or @($records.frame | Sort-Object -Unique).Count -ne $Samples) { throw 'Profiler capture did not produce the requested number of unique fresh frames.' }

$endedUtc = [DateTime]::UtcNow
$timerRows = foreach ($record in $records) {
    foreach ($timer in $record.timers) {
        [pscustomobject][ordered]@{
            sample = $record.sample; timestampUtc = $record.timestampUtc; frame = $record.frame; name = [string]$timer.name
            activeGpu = [bool]$timer.activeGpu; activeCpu = [bool]$timer.activeCpu; hasGpu = [bool]$timer.hasGpu; hasCpu = [bool]$timer.hasCpu
            gpuMs = [double]$timer.gpuMs; topLevelMs = [double]$timer.topLevelMs; cpuMs = [double]$timer.cpuMs
        }
    }
}
$timerSummaries = foreach ($group in ($timerRows | Group-Object name | Sort-Object Name)) {
    $activeGpu = @($group.Group | Where-Object { $_.activeGpu -and $_.hasGpu })
    [pscustomobject][ordered]@{
        name = $group.Name; observedSamples = $group.Count; activeGpuSamples = $activeGpu.Count
        gpuMs = Get-MetricSummary ([double[]]@($activeGpu.gpuMs)); topLevelMs = Get-MetricSummary ([double[]]@($activeGpu.topLevelMs))
        cpuMs = Get-MetricSummary ([double[]]@($group.Group | Where-Object { $_.activeCpu -and $_.hasCpu } | ForEach-Object cpuMs))
    }
}
$summary = [pscustomobject][ordered]@{
    schemaVersion = 3; transactionId = $transactionId; label = $Label; startedUtc = $startedUtc.ToString('o'); endedUtc = $endedUtc.ToString('o')
    durationSeconds = ($endedUtc - $startedUtc).TotalSeconds; requestedSamples = $Samples; warmupSamples = $WarmupSamples; collectedSamples = $records.Count
    uniqueFreshFrames = @($records.frame | Sort-Object -Unique).Count; intervalMs = $IntervalMs; totalTimeoutSeconds = $TotalTimeoutSeconds
    runtimeIdentity = $runtimeIdentity; runtimeIdentityFingerprint = $expectedRuntimeIdentityFingerprint
    context = $context; contextFingerprint = $receipt.contextFingerprint; treatmentFingerprint = $receipt.treatmentFingerprint
    priorProfilerEnabled = $receipt.priorEnabled; profilerStateRestored = $receipt.stateRestored; receiptPath = $receiptPath
    performanceObservations = @($receipt.performanceObservations)
    resourcePublication = [pscustomobject][ordered]@{
        before = $resourcePublicationBefore
        after = $resourcePublicationAfter
    }
    preparation = [pscustomobject][ordered]@{
        before = if ($null -eq $resourcePublicationBefore) { $null } else { $resourcePublicationBefore.preparation }
        after = if ($null -eq $resourcePublicationAfter) { $null } else { $resourcePublicationAfter.preparation }
    }
    resolvedTotalMs = Get-MetricSummary ([double[]]@($records.resolvedTotalMs)); resolvedCpuTotalMs = Get-MetricSummary ([double[]]@($records.resolvedCpuTotalMs))
    maxSlotRefusals = [int](($records | Measure-Object slotRefusals -Maximum).Maximum); timers = @($timerSummaries)
}
$rawPath = Join-Path $runDirectory "$safeLabel.raw.json"
$summaryPath = Join-Path $runDirectory "$safeLabel.summary.json"
$csvPath = Join-Path $runDirectory "$safeLabel.timers.csv"
Write-JsonAtomic $rawPath @($records)
Write-JsonAtomic $summaryPath $summary
$timerSummaries | ForEach-Object {
    [pscustomobject][ordered]@{ name = $_.name; observedSamples = $_.observedSamples; activeGpuSamples = $_.activeGpuSamples; gpuMeanMs = $_.gpuMs.mean; gpuMedianMs = $_.gpuMs.median; gpuP95Ms = $_.gpuMs.p95; gpuP99Ms = $_.gpuMs.p99; gpuMaxMs = $_.gpuMs.max; topLevelMeanMs = $_.topLevelMs.mean; cpuMeanMs = $_.cpuMs.mean }
} | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

[pscustomobject][ordered]@{ ok = $true; label = $Label; transactionId = $transactionId; rawPath = $rawPath; summaryPath = $summaryPath; csvPath = $csvPath; receiptPath = $receiptPath; summary = $summary } | ConvertTo-Json -Depth 80
