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

$entrypointText = Get-Content -LiteralPath $entrypoint -Raw
if ($entrypointText -notmatch 'AddSeconds\(600\)' -or
    $entrypointText -notmatch 'Invoke-BoundedQualificationScript -ScriptPath \$controller' -or
    $entrypointText -notmatch 'Invoke-BoundedQualificationScript -ScriptPath \$runner' -or
    $entrypointText -notmatch 'unresolvedProcess = \[bool\]' -or
    $entrypointText -notmatch 'boundedProcess = \$boundedAttempt' -or
    $entrypointText -notmatch 'state = \$\(if \(\$boundedChildLaunched\) \{ ''unknown'' \}') {
    throw 'Entrypoint does not apply one shared 600-second process deadline to controller and runner children.'
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
