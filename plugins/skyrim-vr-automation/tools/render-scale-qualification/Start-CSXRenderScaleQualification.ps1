# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$FixtureManifestPath = $env:CSX_RENDER_SCALE_FIXTURE_PATH,
    [string]$EvidenceDirectory,
    [switch]$PrMode,
    [string]$BaselinePath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBaselineBuildId,
    [string]$CodexExecutable = 'codex',
    [string]$ProtocolPath = (Join-Path $PSScriptRoot 'protocol.v1.json'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageWatch = [Diagnostics.Stopwatch]::StartNew()
$resolvedEvidence = $null
$packageDeadlineUtc = [DateTime]::UtcNow.AddSeconds(600)
$boundedProcess = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\process-control\Invoke-BoundedProcess.ps1'))

function Get-StableFixturePath {
    if (-not [string]::IsNullOrWhiteSpace($FixtureManifestPath)) {
        return [IO.Path]::GetFullPath($FixtureManifestPath)
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\render-scale-qualification\fixture.json'
}

function Get-StableRuntimePath {
    if (-not [string]::IsNullOrWhiteSpace($RuntimePath)) {
        return [IO.Path]::GetFullPath($RuntimePath)
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    $configurationPath = Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\machine.local.json'
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { return $null }
    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -Depth 20
    $configuredPath = [string]$configuration.devBenchRuntimePath
    if ([string]::IsNullOrWhiteSpace($configuredPath)) { return $null }
    return [IO.Path]::GetFullPath($configuredPath)
}

function Write-PackageResult($Value) {
    $Value | ConvertTo-Json -Depth 100 -Compress:$Compact
    if ($NoExit) { return }
    if ([string]$Value.status -in @('PASS', 'LOCAL_PASS')) { exit 0 }
    if ([string]$Value.status -eq 'INFRASTRUCTURE_ERROR') { exit 4 }
    exit 2
}

function Get-RemainingPackageSeconds {
    $remaining = ($packageDeadlineUtc - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -lt 1) {
        throw [TimeoutException]::new('The unattended qualification exceeded its 600-second process deadline.')
    }
    return [int][Math]::Max(1, [Math]::Ceiling($remaining))
}

function ConvertTo-PowerShellArguments([string]$ScriptPath, [object[]]$Leading, [hashtable]$Named) {
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        $arguments.Add([string]$value)
    }
    foreach ($value in $Leading) { $arguments.Add([string]$value) }
    foreach ($entry in $Named.GetEnumerator()) {
        if ($entry.Value -is [bool]) {
            if ([bool]$entry.Value) { $arguments.Add("-$($entry.Key)") }
            continue
        }
        if ($null -eq $entry.Value) { continue }
        $arguments.Add("-$($entry.Key)")
        $arguments.Add([string]$entry.Value)
    }
    return [string[]]$arguments
}

function Invoke-BoundedQualificationScript(
    [string]$ScriptPath,
    [object[]]$Leading = @(),
    [hashtable]$Named = @{}) {
    if (-not (Test-Path -LiteralPath $boundedProcess -PathType Leaf)) {
        throw "The bounded process controller is missing: $boundedProcess"
    }
    $hostPath = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = ConvertTo-PowerShellArguments -ScriptPath $ScriptPath -Leading $Leading -Named $Named
    $bounded = & $boundedProcess -FilePath $hostPath -ArgumentList $arguments `
        -WorkingDirectory $PSScriptRoot -TimeoutSeconds (Get-RemainingPackageSeconds) `
        -MaxAttempts 1 -RetryPatterns @() -NoExit -Compact | ConvertFrom-Json -Depth 100
    $attempt = @($bounded.attempts | Select-Object -Last 1)
    if ($attempt.Count -ne 1) {
        throw "The bounded qualification process produced no attempt record: $(@($bounded.errors) -join ' ')"
    }
    if ([bool]$attempt[0].timedOut -or [bool]$attempt[0].unresolvedProcess) {
        throw [TimeoutException]::new("The bounded qualification process exceeded the shared 600-second deadline: $ScriptPath")
    }
    if ($null -eq $attempt[0].exitCode -or [int]$attempt[0].exitCode -ne 0) {
        throw "The bounded qualification process failed for '$ScriptPath': $([string]$attempt[0].stderr)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$attempt[0].stdout)) {
        throw "The bounded qualification process returned no output: $ScriptPath"
    }
    return [string]$attempt[0].stdout
}

try {
    $baselineArgumentsSupplied = $PSBoundParameters.ContainsKey('BaselinePath') -or
        $PSBoundParameters.ContainsKey('ExpectedBaselineBuildId')
    if (-not $PrMode -and $baselineArgumentsSupplied) {
        throw 'Baseline inputs require -PrMode; local qualification cannot silently ignore them.'
    }
    if ($PrMode -and
        ([string]::IsNullOrWhiteSpace($BaselinePath) -or [string]::IsNullOrWhiteSpace($ExpectedBaselineBuildId))) {
        throw 'PR mode requires -BaselinePath and -ExpectedBaselineBuildId.'
    }

    $resolvedRuntime = Get-StableRuntimePath
    if ([string]::IsNullOrWhiteSpace($resolvedRuntime)) {
        throw 'No running DevBench runtime was selected. Pass -RuntimePath, set CSX_DEVBENCH_RUNTIME_PATH, or configure devBenchRuntimePath in %LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json before saying start.'
    }
    if (-not (Test-Path -LiteralPath $resolvedRuntime -PathType Leaf)) {
        throw "DevBench runtime metadata does not exist: $resolvedRuntime"
    }
    $resolvedFixture = Get-StableFixturePath
    if ([string]::IsNullOrWhiteSpace($resolvedFixture) -or -not (Test-Path -LiteralPath $resolvedFixture -PathType Leaf)) {
        throw 'No stable render-scale fixture is configured. Pass -FixtureManifestPath, set CSX_RENDER_SCALE_FIXTURE_PATH, or create %LOCALAPPDATA%\SkyrimVRAutomation\render-scale-qualification\fixture.json.'
    }
    $fixture = Get-Content -LiteralPath $resolvedFixture -Raw | ConvertFrom-Json -Depth 50
    $gpuVendor = ([string]$fixture.gpu.vendor).ToUpperInvariant()
    if ($gpuVendor -notin @('NVIDIA', 'AMD')) { throw 'The stable fixture must identify GPU vendor NVIDIA or AMD.' }

    $controller = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\devbench-control\Invoke-DevBenchControl.ps1'))
    if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) { throw 'The bundled DevBench controller is missing.' }
    $listText = Invoke-BoundedQualificationScript -ScriptPath $controller -Leading @('list') -Named @{
        RuntimePath = $resolvedRuntime
        NoExit = $true
        Compact = $true
    }
    $list = $listText | ConvertFrom-Json -Depth 100
    if (-not [bool]$list.ok) { throw "Running DevBench discovery failed: $(@($list.errors) -join ' ')" }
    $buildId = ([string]$list.runtimeIdentity.build.buildId).ToLowerInvariant()
    if ($buildId -notmatch '^[a-f0-9]{64}$') { throw 'The running DLL did not advertise one exact 64-character CSX Build ID.' }
    $artifactSha256 = [string]$list.runtimeIdentity.artifact.sha256

    if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is required when -EvidenceDirectory is omitted.' }
        $evidenceBase = Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\evidence\render-scale-qualification'
        $leaf = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$($buildId.Substring(0, 12))"
        $resolvedEvidence = Join-Path $evidenceBase $leaf
    }
    else { $resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory) }
    if (Test-Path -LiteralPath $resolvedEvidence) { throw "EvidenceDirectory must be new and empty: $resolvedEvidence" }

    $runner = Join-Path $PSScriptRoot 'Invoke-CSXRenderScaleQualification.ps1'
    $arguments = @{
        EvidenceDirectory = $resolvedEvidence
        RuntimePath = $resolvedRuntime
        ExpectedBuildId = $buildId
        GpuVendor = $gpuVendor
        FixtureManifestPath = $resolvedFixture
        CodexExecutable = $CodexExecutable
        ProtocolPath = $ProtocolPath
        NoExit = $true
        Compact = $true
    }
    if ($artifactSha256 -match '^[A-Fa-f0-9]{64}$') { $arguments.ExpectedArtifactSha256 = $artifactSha256 }
    if ($PrMode) {
        $arguments.PrMode = $true
        $arguments.BaselinePath = $BaselinePath
        $arguments.ExpectedBaselineBuildId = $ExpectedBaselineBuildId
    }
    $runnerText = Invoke-BoundedQualificationScript -ScriptPath $runner -Named $arguments
    $runnerResult = $runnerText | ConvertFrom-Json -Depth 100
    if ([string]$runnerResult.status -notin @('PASS', 'LOCAL_PASS', 'FAIL', 'INFRASTRUCTURE_ERROR')) {
        throw "The unattended runner returned an unsupported terminal status: $([string]$runnerResult.status)"
    }
    $packageWatch.Stop()
    $endToEndLimit = [int]((Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json -Depth 100).timeBudget.endToEndMs)
    $elapsedMs = [Math]::Round($packageWatch.Elapsed.TotalMilliseconds, 3)
    if ($elapsedMs -gt $endToEndLimit -and [string]$runnerResult.status -in @('PASS', 'LOCAL_PASS')) {
        throw "The unattended package took $elapsedMs ms, exceeding its $endToEndLimit ms limit."
    }
    $runnerResult | Add-Member -NotePropertyName packageElapsedMs -NotePropertyValue $elapsedMs -Force
    $runnerResult | Add-Member -NotePropertyName evidenceDirectory -NotePropertyValue $resolvedEvidence -Force
    $runnerResult | Add-Member -NotePropertyName discoveredBuildId -NotePropertyValue $buildId -Force
    $runnerResult | Add-Member -NotePropertyName discoveredGpuVendor -NotePropertyValue $gpuVendor -Force
    Write-PackageResult $runnerResult
}
catch {
    if ($packageWatch.IsRunning) { $packageWatch.Stop() }
    Write-PackageResult ([pscustomobject][ordered]@{
        ok = $false
        status = 'INFRASTRUCTURE_ERROR'
        packageElapsedMs = [Math]::Round($packageWatch.Elapsed.TotalMilliseconds, 3)
        evidenceDirectory = $resolvedEvidence
        errors = @($_.Exception.Message)
    })
}
