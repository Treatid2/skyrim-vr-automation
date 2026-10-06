# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$entrypoint = Join-Path $PSScriptRoot 'Start-CSXRenderScaleQualification.ps1'
$runner = Join-Path $PSScriptRoot 'Invoke-CSXRenderScaleQualification.ps1'

function Assert-EntrypointFailure {
    param(
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedError
    )

    $text = & $entrypoint @Arguments -NoExit -Compact | Out-String
    $result = $text | ConvertFrom-Json -Depth 20
    if ([string]$result.status -ne 'INFRASTRUCTURE_ERROR') {
        throw "Entrypoint did not fail closed: $text"
    }
    if ($ExpectedError -notin @($result.errors)) {
        throw "Entrypoint did not report '$ExpectedError': $text"
    }
}

$buildId = 'a' * 64
$baselineError = 'Baseline inputs require -PrMode; local qualification cannot silently ignore them.'
Assert-EntrypointFailure -Arguments @{ BaselinePath = 'C:\baseline' } -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{ ExpectedBaselineBuildId = $buildId } -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{
    BaselinePath = 'C:\baseline'
    ExpectedBaselineBuildId = $buildId
} -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{ PrMode = $true } `
    -ExpectedError 'PR mode requires -BaselinePath and -ExpectedBaselineBuildId.'

$missingPropertyRoot = Join-Path ([IO.Path]::GetTempPath()) "csx-qualification-missing-runtime-$([guid]::NewGuid().ToString('N'))"
$missingPropertyEvidence = Join-Path $missingPropertyRoot 'evidence'
$priorLocalAppData = $env:LOCALAPPDATA
$priorRuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH
try {
    $configDirectory = Join-Path $missingPropertyRoot 'SkyrimVRAutomation'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $configDirectory 'machine.local.json') -Encoding utf8
    $env:LOCALAPPDATA = $missingPropertyRoot
    $env:CSX_DEVBENCH_RUNTIME_PATH = $null
    $preflightText = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -NonInteractive -File $entrypoint `
        -EvidenceDirectory $missingPropertyEvidence -Compact | Out-String
    $preflightExitCode = $LASTEXITCODE
    $preflightResult = $preflightText | ConvertFrom-Json -Depth 20
    if ($preflightExitCode -ne 4 -or
        [string]$preflightResult.status -ne 'INFRASTRUCTURE_ERROR' -or
        $null -ne $preflightResult.processId -or
        [string]$preflightResult.runtimeCleanup.state -cne 'not_applicable') {
        throw "Missing optional runtime property did not produce a no-child infrastructure exit 4: $preflightText"
    }
    if ('No running DevBench runtime was selected. Pass -RuntimePath, set CSX_DEVBENCH_RUNTIME_PATH, or configure devBenchRuntimePath in %LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json before saying start.' -notin @($preflightResult.errors)) {
        throw "Missing optional runtime property did not produce actionable guidance: $preflightText"
    }
    if ([string]$preflightResult.preflightReceiptPath -cne (Join-Path $missingPropertyEvidence 'qualification-preflight.failure.json') -or
        -not (Test-Path -LiteralPath ([string]$preflightResult.preflightReceiptPath) -PathType Leaf)) {
        throw "Missing optional runtime property did not retain its preflight receipt: $preflightText"
    }
}
finally {
    $env:LOCALAPPDATA = $priorLocalAppData
    $env:CSX_DEVBENCH_RUNTIME_PATH = $priorRuntimePath
    if (Test-Path -LiteralPath $missingPropertyRoot) { Remove-Item -LiteralPath $missingPropertyRoot -Recurse -Force }
}

$runnerCommon = @{
    EvidenceDirectory = Join-Path ([IO.Path]::GetTempPath()) "csx-runner-admission-$([guid]::NewGuid().ToString('N'))"
    RuntimePath = 'C:\missing-runtime.json'
    ExpectedBuildId = $buildId
    GpuVendor = 'NVIDIA'
    FixtureManifestPath = 'C:\missing-fixture.json'
}
foreach ($baselineArguments in @(
    @{ BaselinePath = 'C:\baseline' },
    @{ ExpectedBaselineBuildId = $buildId },
    @{ BaselinePath = 'C:\baseline'; ExpectedBaselineBuildId = $buildId }
)) {
    $arguments = $runnerCommon.Clone()
    foreach ($entry in $baselineArguments.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
    $runnerText = & $runner @arguments -NoExit -Compact | Out-String
    $runnerResult = $runnerText | ConvertFrom-Json -Depth 20
    if ($baselineError -notin @($runnerResult.errors)) {
        throw "Direct runner did not enforce explicit PR-mode admission: $runnerText"
    }
}
$incompletePrArguments = $runnerCommon.Clone()
$incompletePrArguments.PrMode = $true
$runnerText = & $runner @incompletePrArguments -NoExit -Compact | Out-String
$runnerResult = $runnerText | ConvertFrom-Json -Depth 20
if ('PR mode requires a matching baseline artifact and explicit baseline Build ID.' -notin @($runnerResult.errors)) {
    throw "Direct runner did not reject incomplete PR-mode baseline admission: $runnerText"
}

$expiredArguments = $runnerCommon.Clone()
$expiredArguments.PackageDeadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
$runnerText = & $runner @expiredArguments -NoExit -Compact | Out-String
$runnerResult = $runnerText | ConvertFrom-Json -Depth 20
if ('The complete qualification result deadline already elapsed.' -notin @($runnerResult.errors)) {
    throw "Direct runner did not reject an expired shared deadline before runtime admission: $runnerText"
}

$qualificationModule = Join-Path $PSScriptRoot 'RenderScaleQualification.psm1'
$moduleLiteral = $qualificationModule.Replace("'", "''")
$exportProbe = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -NonInteractive -Command `
    "Import-Module '$moduleLiteral' -Force; if (-not (Get-Command Test-CSXQualificationCompletionReceipt -ErrorAction SilentlyContinue)) { exit 9 }; 'EXPORTED'" | Out-String
if ($LASTEXITCODE -ne 0 -or $exportProbe.Trim() -ne 'EXPORTED') {
    throw 'A clean PowerShell process cannot reach the qualification completion validator used by baseline admission.'
}

$entrypointText = Get-Content -LiteralPath $entrypoint -Raw
$runnerSource = Get-Content -LiteralPath $runner -Raw
if ($entrypointText -notmatch 'AddSeconds\(600\)' -or
    $entrypointText -notmatch 'Invoke-BoundedQualificationScript -ScriptPath \$controller' -or
    $entrypointText -notmatch 'Invoke-BoundedQualificationScript -ScriptPath \$runner' -or
    $entrypointText -notmatch '\$bounded\.deadlineSatisfied' -or
    $entrypointText -notmatch '\$attempt\[0\]\.processTreeOwned' -or
    $entrypointText -notmatch '\$attempt\[0\]\.jobQuiescent' -or
    $entrypointText -notmatch '\$attempt\[0\]\.jobClosed' -or
    $entrypointText -notmatch '\$attempt\[0\]\.exitVerified' -or
    $entrypointText -notmatch '\$attempt\[0\]\.streamDrainComplete' -or
    $entrypointText -match "Write-CSXJsonFile.*qualification-package-rejection\.json" -or
    $entrypointText -notmatch 'unresolvedProcess = \[bool\]' -or
    $entrypointText -notmatch 'boundedProcess = \$boundedAttempt' -or
    $entrypointText -notmatch 'state = \$\(if \(\$boundedChildLaunched\) \{ ''unknown'' \}') {
    throw 'Entrypoint does not apply one shared 600-second process deadline to controller and runner children.'
}
if ($runnerSource -notmatch 'Get-CSXResultBoundedTimeoutSeconds' -or
    $runnerSource -notmatch "Assert-CSXResultBudget -Stage 'post-binding admission'" -or
    $runnerSource -notmatch 'CommandTimeoutMilliseconds \$providerCommandTimeoutMs' -or
    $runnerSource -notmatch 'remainingResultWorkMs' -or
    $runnerSource -notmatch 'TimeoutSeconds \(Get-CSXResultBoundedTimeoutSeconds -OperationCapMs 5000\)' -or
    $runnerSource -match 'Update-CSXQualificationReport -EvidenceDirectory \$script:evidenceRoot -AllowUnsealedSuccess' -or
    $runnerSource -notmatch 'Complete-CSXSealedQualification -EvidenceDirectory \$script:evidenceRoot' -or
    $runnerSource -notmatch '(?s)qualification-completion\.json.*Update-CSXQualificationReport -EvidenceDirectory \$script:evidenceRoot') {
    throw 'Direct runner does not propagate the shared result deadline and sealed-success boundary through production operations.'
}

$skillPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
    'skills\render-scale-qualification\SKILL.md'
$skillText = Get-Content -LiteralPath $skillPath -Raw
$description = [regex]::Match($skillText, '(?m)^description:\s*(.+)$').Groups[1].Value
if ($description -match 'contextually says start' -or
    $skillText -notmatch 'contextual `start` is not sufficient authorization') {
    throw 'Render-scale qualification routing still accepts an ambiguous contextual start.'
}

$schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot `
    'visual-review.output-schema.v1.json') -Raw | ConvertFrom-Json -Depth 30
$requiredOrdinals = @($schema.properties.samples.allOf | ForEach-Object {
        [int]$_.contains.properties.ordinal.const
    } | Sort-Object)
if (($requiredOrdinals -join ',') -ne '1,8,16' -or
    @($schema.properties.samples.allOf | Where-Object {
            [int]$_.minContains -ne 1 -or [int]$_.maxContains -ne 1
        }).Count -ne 0) {
    throw 'Visual review schema does not require exactly one sample for ordinals 1, 8, and 16.'
}

'Render-scale qualification entrypoint tests passed.'
